defmodule Tymeslot.Emails.EmailScheduler.AccountSchedulerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :unit

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Emails.EmailScheduler.{AccountScheduler, LinkArg}
  alias Tymeslot.Workers.EmailWorker

  # Count what each call *adds* rather than asserting absolute totals, so the
  # assertions stay tied to the function under test and keep passing even if
  # setup (factories, other scheduled emails) ever enqueues EmailWorker jobs
  # of its own.
  defp email_job_count, do: length(all_enqueued(worker: EmailWorker))

  describe "schedule_email_change_emails/4" do
    test "enqueues verification and notification jobs with correct args" do
      user = insert(:user)
      new_email = "new@example.com"
      verification_url = "https://example.com/verify/token123"
      baseline = email_job_count()

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 new_email,
                 verification_url,
                 "hash-1"
               )

      assert email_job_count() - baseline == 2

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_change_verification",
          "user_id" => user.id,
          "new_email" => new_email,
          "token_hash" => "hash-1"
        }
      )

      # The link holds a live token, so it is stored encrypted, never in the clear.
      [job] =
        all_enqueued(worker: EmailWorker, args: %{"action" => "send_email_change_verification"})

      refute Map.has_key?(job.args, "verification_url")
      refute Jason.encode!(job.args) =~ verification_url
      assert LinkArg.fetch(job.args, "verification_url") == {:ok, verification_url}

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_change_notification",
          "user_id" => user.id,
          "new_email" => new_email
        }
      )
    end

    test "duplicate call within 10-minute window does not create new jobs" do
      user = insert(:user)
      new_email = "new@example.com"
      verification_url = "https://example.com/verify/token123"
      baseline = email_job_count()

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 new_email,
                 verification_url,
                 "hash-1"
               )

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 new_email,
                 verification_url,
                 "hash-1"
               )

      assert email_job_count() - baseline == 2
    end

    test "a fresh token for the same address gets its own verification email" do
      user = insert(:user)
      baseline = email_job_count()

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 "new@example.com",
                 "https://example.com/verify/token-1",
                 "hash-1"
               )

      # A second request replaced the stored token, so the first link is dead
      # and the new one must be sent; the notification is still coalesced.
      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 "new@example.com",
                 "https://example.com/verify/token-2",
                 "hash-2"
               )

      assert email_job_count() - baseline == 3
    end

    test "different new_email creates additional jobs" do
      user = insert(:user)
      verification_url = "https://example.com/verify/token123"
      baseline = email_job_count()

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 "first@example.com",
                 verification_url,
                 "hash-1"
               )

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 "second@example.com",
                 verification_url,
                 "hash-2"
               )

      assert email_job_count() - baseline == 4
    end
  end

  describe "schedule_email_change_confirmations/3" do
    test "enqueues confirmation job with correct args" do
      user = insert(:user)
      old_email = "old@example.com"
      new_email = "new@example.com"

      assert :ok =
               AccountScheduler.schedule_email_change_confirmations(
                 user.id,
                 old_email,
                 new_email
               )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_change_confirmations",
          "user_id" => user.id,
          "old_email" => old_email,
          "new_email" => new_email
        }
      )
    end

    test "enqueues exactly one job" do
      user = insert(:user)
      baseline = email_job_count()

      assert :ok =
               AccountScheduler.schedule_email_change_confirmations(
                 user.id,
                 "old@example.com",
                 "new@example.com"
               )

      assert email_job_count() - baseline == 1
    end

    test "duplicate call within 1-hour window does not create new jobs" do
      user = insert(:user)
      old_email = "old@example.com"
      new_email = "new@example.com"

      assert :ok =
               AccountScheduler.schedule_email_change_confirmations(
                 user.id,
                 old_email,
                 new_email
               )

      assert :ok =
               AccountScheduler.schedule_email_change_confirmations(
                 user.id,
                 old_email,
                 new_email
               )

      jobs =
        all_enqueued(
          worker: EmailWorker,
          args: %{
            "action" => "send_email_change_confirmations",
            "user_id" => user.id
          }
        )

      assert length(jobs) == 1
    end
  end
end
