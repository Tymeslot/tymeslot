defmodule Tymeslot.Workers.EmailWorkerExecutionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

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

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_emails, fn _details ->
        {{:ok, :sent}, {:ok, :sent}}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })
    end

    test "discards job on partial failure to avoid duplicate sends" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_emails, fn _details ->
        {{:ok, :sent}, {:error, :delivery_failed}}
      end)

      assert {:discard, _reason} =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })
    end

    test "returns error on total failure so job is retried" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_emails, fn _details ->
        {{:error, :delivery_failed}, {:error, :delivery_failed}}
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
      assert {:discard, "Missing action parameter"} =
               perform_job(EmailWorker, %{"meeting_id" => 123})
    end

    test "discards job with unknown action" do
      assert {:discard, reason} =
               perform_job(EmailWorker, %{
                 "action" => "unknown_action",
                 "meeting_id" => 123
               })

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
                 "meeting_id" => fake_id
               })
    end

    test "discards job if meeting is cancelled for reminders" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      assert {:discard, "Meeting cancelled"} =
               perform_job(EmailWorker, %{
                 "action" => "send_reminder_emails",
                 "meeting_id" => meeting.id
               })
    end

    test "discards job if user not found for email verification" do
      assert {:discard, "User not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_verification",
                 "user_id" => 999_999,
                 "verification_url" => "http://test.com"
               })
    end

    test "discards job if user not found for password reset" do
      assert {:discard, "User not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_password_reset",
                 "user_id" => 999_999,
                 "reset_url" => "http://test.com"
               })
    end

    test "discards send_email_change_verification job if user not found" do
      assert {:discard, "User not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_change_verification",
                 "user_id" => 999_999,
                 "new_email" => "new@example.com",
                 "verification_url" => "https://example.com/verify/token"
               })
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

  describe "backoff/1" do
    test "calculates exponential backoff: 1s, 2s, 4s, 8s, 16s" do
      assert EmailWorker.backoff(%Oban.Job{attempt: 1}) == 1
      assert EmailWorker.backoff(%Oban.Job{attempt: 2}) == 2
      assert EmailWorker.backoff(%Oban.Job{attempt: 3}) == 4
      assert EmailWorker.backoff(%Oban.Job{attempt: 4}) == 8
      assert EmailWorker.backoff(%Oban.Job{attempt: 5}) == 16
    end

    test "caps backoff at 16 seconds" do
      assert EmailWorker.backoff(%Oban.Job{attempt: 6}) == 16
      assert EmailWorker.backoff(%Oban.Job{attempt: 10}) == 16
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
      assert job.max_attempts == 5
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
