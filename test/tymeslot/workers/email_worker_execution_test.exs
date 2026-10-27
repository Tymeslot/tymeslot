defmodule Tymeslot.Workers.EmailWorkerExecutionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Emails.EmailScheduler.LinkArg
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.DeliveryClaims.DeliveryClaimQueries
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  # A job already in the queue is never rebuilt, so one whose args the
  # current `EmailWorker.new/2` would refuse (inserted by older code) still
  # reaches `perform/1`; `perform_job/2` would refuse it first.
  defp perform_queued(args), do: EmailWorker.perform(%Oban.Job{args: args, attempt: 1})

  defp admin_alert_args do
    %{
      "action" => "send_admin_alert",
      "recipient" => "ops@example.com",
      "category" => "Queue",
      "severity" => "error",
      "message" => "Oban job failed permanently",
      "metadata" => %{"worker" => "Tymeslot.Workers.EmailWorker"},
      "alert_hash" => String.duplicate("a", 64)
    }
  end

  describe "perform/1 send_cancellation_emails" do
    test "discards job when meeting is not found" do
      assert {:discard, "Meeting not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => UUID.generate()
               })
    end

    test "discards job when meeting is not cancelled" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user)

      assert {:discard, "Meeting not cancelled"} =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })
    end

    test "sends cancellation emails for a cancelled meeting" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, fn _email,
                                                                                      _details ->
        {:ok, :sent}
      end)

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, fn _email,
                                                                                     _details ->
        {:ok, :sent}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })
    end

    # The Oban lifeline re-runs a job orphaned after it sent; a cancellation
    # has no per-recipient sent flag on the meeting, so the job's own claims
    # are what keep the second run from mailing everyone again. The Mox
    # expectations fail the test on a second call.
    test "a rescued job sends the participant and guest cancellations only once" do
      profile = insert(:profile)

      meeting =
        insert(:meeting,
          organizer_user: profile.user,
          status: "cancelled",
          first_announced_at: DateTime.utc_now(:second)
        )

      {:ok, [_guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, 1, fn _email,
                                                                                     _details ->
        {:ok, :sent}
      end)

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, 1, fn _email,
                                                                                    _details ->
        {:ok, :sent}
      end)

      expect(Tymeslot.EmailServiceMock, :send_guest_cancellation, 1, fn "guest@example.com",
                                                                        _details ->
        {:ok, :sent}
      end)

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_cancellation_emails",
          "meeting_id" => meeting.id
        })

      assert :ok = EmailWorker.perform(job)
      assert :ok = EmailWorker.perform(job)
    end

    # A node that stops part-way through the guests leaves the claims of those
    # already mailed; the rescued run must still reach the others.
    test "a job rescued part-way through the guests tells the guests not yet told" do
      profile = insert(:profile)

      meeting =
        insert(:meeting,
          organizer_user: profile.user,
          status: "cancelled",
          first_announced_at: DateTime.utc_now(:second)
        )

      {:ok, guests} =
        Guests.create_for_meeting(meeting.id, ["told@example.com", "untold@example.com"])

      told = Enum.find(guests, &(&1.email == "told@example.com"))

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_cancellation_emails",
          "meeting_id" => meeting.id
        })

      :claimed = DeliveryClaimQueries.claim(job.id, "cancellation:participants")
      :claimed = DeliveryClaimQueries.claim(job.id, "cancellation:guest:#{told.id}")

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, 0, fn _email,
                                                                                     _details ->
        {:ok, :sent}
      end)

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, 0, fn _email,
                                                                                    _details ->
        {:ok, :sent}
      end)

      expect(Tymeslot.EmailServiceMock, :send_guest_cancellation, 1, fn "untold@example.com",
                                                                        _details ->
        {:ok, :sent}
      end)

      assert :ok = EmailWorker.perform(job)
    end

    # The organiser's copy goes out inline after the per-seat jobs are
    # dispatched, and the guests are told only after that. An organiser
    # address the provider refuses outright must not end the job before the
    # guests hear the meeting is off.
    test "a group meeting whose organiser address is rejected still tells the guests" do
      profile = insert(:profile)

      meeting =
        insert(:group_meeting,
          capacity: 4,
          organizer_user_id: profile.user.id,
          status: "cancelled"
        )

      participant = insert(:participant, meeting: meeting)

      {:ok, [guest]} =
        Guests.create_for_participant(meeting.id, participant.id, ["guest@example.com"])

      {:ok, _guest} = GuestQueries.mark_confirmation_sent(guest, DateTime.utc_now(:second))

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, 1, fn _email,
                                                                                     _details ->
        {:error, {:recipient_rejected, "550 no such user"}}
      end)

      expect(Tymeslot.EmailServiceMock, :send_guest_cancellation, 1, fn "guest@example.com",
                                                                        _details ->
        {:ok, :sent}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })

      assert_enqueued(
        worker: EmailWorker,
        args: %{"meeting_id" => meeting.id, "participant_id" => participant.id}
      )
    end

    test "a retry after a total failure sends the cancellation again" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, 1, fn _email,
                                                                                     _details ->
        {:error, :delivery_failed}
      end)

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, 1, fn _email,
                                                                                    _details ->
        {:error, :delivery_failed}
      end)

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, 1, fn _email,
                                                                                     _details ->
        {:ok, :sent}
      end)

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, 1, fn _email,
                                                                                    _details ->
        {:ok, :sent}
      end)

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_cancellation_emails",
          "meeting_id" => meeting.id
        })

      assert {:error, _reason} = EmailWorker.perform(job)
      assert :ok = EmailWorker.perform(%{job | attempt: 2})
    end

    test "a partial failure errors the job and the retry sends only the copy that failed" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      # The organiser's copy goes out on the first run only; the attendee's
      # fails once and is the only one sent again.
      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, 1, fn _email,
                                                                                     _details ->
        {:ok, :sent}
      end)

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, 1, fn _email,
                                                                                    _details ->
        {:error, :delivery_failed}
      end)

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, 1, fn _email,
                                                                                    _details ->
        {:ok, :sent}
      end)

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_cancellation_emails",
          "meeting_id" => meeting.id
        })

      assert {:error, _reason} = EmailWorker.perform(job)
      assert :ok = EmailWorker.perform(%{job | attempt: 2})
    end

    test "a job holding the legacy participants claim sends no participant copy but tells an unclaimed guest" do
      profile = insert(:profile)

      meeting =
        insert(:meeting,
          organizer_user: profile.user,
          status: "cancelled",
          first_announced_at: DateTime.utc_now(:second)
        )

      {:ok, [_guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_cancellation_emails",
          "meeting_id" => meeting.id
        })

      :ok = DeliveryClaims.once(job.id, "cancellation:participants", fn -> :ok end)

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, 0, fn _email,
                                                                                     _details ->
        {:ok, :sent}
      end)

      expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, 0, fn _email,
                                                                                    _details ->
        {:ok, :sent}
      end)

      expect(Tymeslot.EmailServiceMock, :send_guest_cancellation, 1, fn "guest@example.com",
                                                                        _details ->
        {:ok, :sent}
      end)

      assert :ok = EmailWorker.perform(job)
    end

    test "returns error on total failure so job is retried" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, fn _email,
                                                                                      _details ->
        {:error, :delivery_failed}
      end)

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, fn _email,
                                                                                     _details ->
        {:error, :delivery_failed}
      end)

      assert {:error, _reason} =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })
    end

    # A permanent rejection of one recipient used to discard the whole job,
    # throwing away the other recipient's still-retryable send. Neither
    # succeeded here, so nothing has gone out yet: the job must retry, not
    # discard, or the still-live recipient never gets their cancellation
    # email.
    test "retries rather than discarding when one recipient is rejected and the other fails transiently" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, fn _email,
                                                                                      _details ->
        {:error, {:recipient_rejected, {422, %{"ErrorCode" => 406}}}}
      end)

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, fn _email,
                                                                                     _details ->
        {:error, :delivery_failed}
      end)

      assert {:error, _reason} =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })
    end
  end

  describe "perform/1 error handling" do
    test "discards job with missing action parameter" do
      assert {:discard, "Missing action parameter"} = perform_queued(%{"meeting_id" => 123})
    end

    test "discards job with unknown action" do
      assert {:discard, reason} =
               perform_queued(%{"action" => "unknown_action", "meeting_id" => 123})

      assert reason =~ "Unknown action"
    end

    test "discards job if meeting not found for confirmations" do
      fake_id = UUID.generate()

      assert {:discard, "Meeting not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_confirmation_emails",
                 "meeting_id" => fake_id
               })
    end

    test "discards job if meeting not found for reminders" do
      fake_id = UUID.generate()

      assert {:discard, "Meeting not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_reminder_emails",
                 "meeting_id" => fake_id,
                 "reminder_value" => 1,
                 "reminder_unit" => "hours"
               })
    end

    test "discards job if meeting is cancelled for reminders" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      assert {:discard, "Meeting cancelled"} =
               perform_job(EmailWorker, %{
                 "action" => "send_reminder_emails",
                 "meeting_id" => meeting.id,
                 "reminder_value" => 1,
                 "reminder_unit" => "hours"
               })
    end

    test "discards job if user not found for email verification" do
      assert {:discard, "User not found"} =
               perform_job(
                 EmailWorker,
                 LinkArg.put(
                   %{"action" => "send_email_verification", "user_id" => 999_999},
                   "verification_url",
                   "http://test.com"
                 )
               )
    end

    test "discards job if user not found for password reset" do
      assert {:discard, "User not found"} =
               perform_job(
                 EmailWorker,
                 LinkArg.put(
                   %{"action" => "send_password_reset", "user_id" => 999_999},
                   "reset_url",
                   "http://test.com"
                 )
               )
    end

    test "discards send_email_change_verification job if user not found" do
      assert {:discard, "User not found"} =
               perform_job(
                 EmailWorker,
                 LinkArg.put(
                   %{
                     "action" => "send_email_change_verification",
                     "user_id" => 999_999,
                     "new_email" => "new@example.com",
                     "token_hash" => "hash"
                   },
                   "verification_url",
                   "https://example.com/verify/token"
                 )
               )
    end

    test "discards send_email_change_notification job if user not found" do
      assert {:discard, "User not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_change_notification",
                 "user_id" => 999_999,
                 "new_email" => "new@example.com"
               })
    end

    test "discards send_email_change_confirmations job if user not found" do
      assert {:discard, "User not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_change_confirmations",
                 "user_id" => 999_999,
                 "old_email" => "old@example.com",
                 "new_email" => "new@example.com"
               })
    end
  end

  describe "perform/1 send_admin_alert" do
    test "happy path: returns :ok when all required fields are present" do
      Mox.expect(Tymeslot.EmailServiceMock, :send_admin_alert, fn _recipient,
                                                                  _category,
                                                                  _severity,
                                                                  _message,
                                                                  _metadata ->
        {:ok, "sent"}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_admin_alert",
                 "recipient" => "ops@example.com",
                 "category" => "Webhook",
                 "severity" => "warning",
                 "message" => "Unhandled webhook event",
                 "metadata" => %{"event_id" => "evt_001"},
                 "alert_hash" => String.duplicate("a", 64)
               })
    end
  end

  describe "perform/1 when the provider's circuit breaker is open" do
    setup do
      Mox.expect(Tymeslot.EmailServiceMock, :send_admin_alert, fn _recipient,
                                                                  _category,
                                                                  _severity,
                                                                  _message,
                                                                  _metadata ->
        {:error, :circuit_open}
      end)

      :ok
    end

    # Snoozing spends no attempt, so the attempts are kept for failures the
    # breaker does not cover, and a paused provider is waited out instead.
    test "snoozes for at least the breaker's recovery window" do
      assert {:snooze, seconds} = perform_job(EmailWorker, admin_alert_args())

      assert seconds >= CircuitBreakerSupervisor.email_breaker_recovery_seconds()
      assert seconds > EmailWorker.backoff(%Oban.Job{attempt: 5})
    end
  end

  describe "perform/1 when the recipient is permanently rejected" do
    test "discards rather than retrying an address that can never accept mail" do
      Mox.expect(Tymeslot.EmailServiceMock, :send_admin_alert, fn _recipient,
                                                                  _category,
                                                                  _severity,
                                                                  _message,
                                                                  _metadata ->
        {:error, {:recipient_rejected, {422, %{"ErrorCode" => 406}}}}
      end)

      assert {:discard, "Recipient permanently undeliverable"} =
               perform_job(EmailWorker, admin_alert_args())
    end

    # Each handler flattens delivery failures into its own message; the
    # classification has to survive that in every one of them, not just the
    # admin alert path the incident happened to expose.
    test "applies to the auth handlers too" do
      user = insert(:user)

      Mox.expect(Tymeslot.EmailServiceMock, :send_email_verification, fn _user, _url ->
        {:error, {:recipient_rejected, {422, %{"ErrorCode" => 300}}}}
      end)

      assert {:discard, "Recipient permanently undeliverable"} =
               perform_job(
                 EmailWorker,
                 LinkArg.put(
                   %{"action" => "send_email_verification", "user_id" => user.id},
                   "verification_url",
                   "https://example.com/verify/token"
                 )
               )
    end
  end

  describe "backoff/1" do
    test "doubles from one second" do
      assert Enum.map(1..7, &EmailWorker.backoff(%Oban.Job{attempt: &1})) ==
               [1, 2, 4, 8, 16, 32, 64]
    end

    test "caps at two minutes" do
      assert EmailWorker.backoff(%Oban.Job{attempt: 8}) == 120
      assert EmailWorker.backoff(%Oban.Job{attempt: 10}) == 120
    end

    # A job's copies share its attempts, so its retries have to outlast a
    # short provider outage, not just a blip.
    test "ten attempts span several minutes of a failing provider" do
      total = Enum.sum(Enum.map(1..9, &EmailWorker.backoff(%Oban.Job{attempt: &1})))
      assert total >= 5 * 60
    end
  end

  describe "job configuration" do
    test "worker is configured with correct queue and max_attempts" do
      # Oban worker configuration is compile-time
      # We can verify through job creation
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      EmailScheduler.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
      assert job.max_attempts == 10
    end

    test "confirmation emails have priority 0 (highest)" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      EmailScheduler.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "reminder emails have priority 2 (medium)" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.add(DateTime.utc_now(), 30, :minute)

      EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 2
    end
  end
end
