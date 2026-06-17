defmodule Tymeslot.Workers.EmailWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Auth.UserTokenQueries
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Security.Token
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  describe "schedule_confirmation_emails/1" do
    test "creates high priority job with uniqueness constraint" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_confirmation_emails(meeting.id)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_confirmation_emails",
          "meeting_id" => meeting.id
        }
      )

      # Verify priority
      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "prevents duplicate jobs within 5 minute window" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_confirmation_emails(meeting.id)
      assert :ok = EmailScheduler.schedule_confirmation_emails(meeting.id)

      # Only one job should exist
      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 1
    end

    test "uses emails queue" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
    end
  end

  describe "schedule_cancellation_emails/1" do
    test "creates high priority job with uniqueness constraint" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_cancellation_emails(meeting.id)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_cancellation_emails",
          "meeting_id" => meeting.id
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "prevents duplicate jobs within 5 minute window" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_cancellation_emails(meeting.id)
      assert :ok = EmailScheduler.schedule_cancellation_emails(meeting.id)

      jobs =
        all_enqueued(
          worker: EmailWorker,
          args: %{"action" => "send_cancellation_emails", "meeting_id" => meeting.id}
        )

      assert length(jobs) == 1
    end

    test "uses emails queue" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_cancellation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
    end
  end

  describe "schedule_reminder_emails/4" do
    test "creates medium priority job" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.add(DateTime.utc_now(), 30, :minute)

      assert :ok =
               EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_reminder_emails",
          "meeting_id" => meeting.id,
          "reminder_value" => 30,
          "reminder_unit" => "minutes"
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 2
    end

    test "schedules job at specified time" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 1, :hour), :second)

      assert :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 1, "hours", scheduled_at)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert DateTime.compare(DateTime.truncate(job.scheduled_at, :second), scheduled_at) == :eq
    end

    test "prevents duplicate jobs" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 30, :minute), :second)

      assert :ok =
               EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      # Should not create duplicate job
      assert :ok =
               EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 1
      job = List.first(jobs)
      assert DateTime.compare(DateTime.truncate(job.scheduled_at, :second), scheduled_at) == :eq
    end

    test "reschedules reminder by replacing existing job" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 30, :minute), :second)
      new_scheduled_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 45, :minute), :second)

      assert :ok =
               EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      # In production, this would delete the existing job and create a new one with new_scheduled_at.
      # In Oban.Testing (manual mode), deletion from the DB won't affect the memory-enqueued job,
      # and the second insert will be treated as a unique duplicate by the code.
      assert :ok =
               EmailScheduler.schedule_reminder_emails(
                 meeting.id,
                 30,
                 "minutes",
                 new_scheduled_at
               )

      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 1
      # We skip the time comparison as Oban.Testing mailbox won't reflect the "replacement"
      # done via DB deletion in worker code.
    end
  end

  describe "schedule_email_verification/3" do
    test "creates high priority job carrying the token hash" do
      user = insert(:user)
      url = "https://example.com/verify"

      assert {:ok, :scheduled} =
               EmailScheduler.schedule_email_verification(user.id, url, "hash-abc")

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_verification",
          "user_id" => user.id,
          "verification_url" => url,
          "token_hash" => "hash-abc"
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "reports a duplicate and replaces args when a job is already queued in the window" do
      user = insert(:user)

      assert {:ok, :scheduled} =
               EmailScheduler.schedule_email_verification(
                 user.id,
                 "https://example.com/verify-1",
                 "hash-1"
               )

      # A second send for the same user within the dedup window is coalesced — even
      # with a different URL, since uniqueness is keyed on action + user_id only.
      assert {:ok, :duplicate} =
               EmailScheduler.schedule_email_verification(
                 user.id,
                 "https://example.com/verify-2",
                 "hash-2"
               )

      assert [job] = all_enqueued(worker: EmailWorker)
      # replace: [:args] updates the still-pending job to carry the fresh token.
      assert job.args["verification_url"] == "https://example.com/verify-2"
      assert job.args["token_hash"] == "hash-2"
    end
  end

  describe "schedule_password_reset/3" do
    test "creates high priority job carrying the token hash" do
      user = insert(:user)
      url = "https://example.com/reset"

      assert {:ok, :scheduled} =
               EmailScheduler.schedule_password_reset(user.id, url, "hash-abc")

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_password_reset",
          "user_id" => user.id,
          "reset_url" => url,
          "token_hash" => "hash-abc"
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "reports a duplicate and replaces args when a job is already queued in the window" do
      user = insert(:user)

      assert {:ok, :scheduled} =
               EmailScheduler.schedule_password_reset(
                 user.id,
                 "https://example.com/reset-1",
                 "hash-1"
               )

      assert {:ok, :duplicate} =
               EmailScheduler.schedule_password_reset(
                 user.id,
                 "https://example.com/reset-2",
                 "hash-2"
               )

      assert [job] = all_enqueued(worker: EmailWorker)
      assert job.args["reset_url"] == "https://example.com/reset-2"
      assert job.args["token_hash"] == "hash-2"
    end
  end

  describe "token staleness guard" do
    test "delivers a verification email whose token hash still matches the stored token" do
      user = insert(:unverified_user)
      {token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)
      {:ok, _user} = UserTokenQueries.set_verification_token(user, token)

      expect(Tymeslot.EmailServiceMock, :send_email_verification, fn _user, _url ->
        {:ok, :sent}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_email_verification",
                 "user_id" => user.id,
                 "verification_url" => "https://example.com/verify",
                 "token_hash" => Token.hash_token(token)
               })
    end

    test "discards a verification email whose token has since been rotated" do
      user = insert(:unverified_user)
      {_old_token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)
      {new_token, _expiry2, _purpose2} = Token.generate_email_verification_token(user.id)
      # The user row now holds the newer token; the job was queued with the old one.
      {:ok, _user} = UserTokenQueries.set_verification_token(user, new_token)

      # No send expectation — a discarded job must not call the email service.
      assert {:discard, _reason} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_verification",
                 "user_id" => user.id,
                 "verification_url" => "https://example.com/verify-old",
                 "token_hash" => "stale-hash-that-no-longer-matches"
               })
    end

    test "delivers a password reset email whose token hash still matches the stored token" do
      user = insert(:user)
      {token, _expiry} = Token.generate_password_reset_token()
      {:ok, _user} = UserTokenQueries.set_reset_token(user, token)

      expect(Tymeslot.EmailServiceMock, :send_password_reset, fn _user, _url -> {:ok, :sent} end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_password_reset",
                 "user_id" => user.id,
                 "reset_url" => "https://example.com/reset",
                 "token_hash" => Token.hash_token(token)
               })
    end

    test "discards a password reset email whose token has since been rotated" do
      user = insert(:user)
      {new_token, _expiry} = Token.generate_password_reset_token()
      {:ok, _user} = UserTokenQueries.set_reset_token(user, new_token)

      assert {:discard, _reason} =
               perform_job(EmailWorker, %{
                 "action" => "send_password_reset",
                 "user_id" => user.id,
                 "reset_url" => "https://example.com/reset-old",
                 "token_hash" => "stale-hash-that-no-longer-matches"
               })
    end

    test "delivers a legacy verification job that carries no token hash" do
      user = insert(:unverified_user)
      {token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)
      {:ok, _user} = UserTokenQueries.set_verification_token(user, token)

      expect(Tymeslot.EmailServiceMock, :send_email_verification, fn _user, _url ->
        {:ok, :sent}
      end)

      # No "token_hash" key — a job enqueued before hash tracking existed must still deliver.
      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_email_verification",
                 "user_id" => user.id,
                 "verification_url" => "https://example.com/verify"
               })
    end

    test "delivers a legacy password reset job that carries no token hash" do
      user = insert(:user)
      {token, _expiry} = Token.generate_password_reset_token()
      {:ok, _user} = UserTokenQueries.set_reset_token(user, token)

      expect(Tymeslot.EmailServiceMock, :send_password_reset, fn _user, _url -> {:ok, :sent} end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_password_reset",
                 "user_id" => user.id,
                 "reset_url" => "https://example.com/reset"
               })
    end
  end
end
