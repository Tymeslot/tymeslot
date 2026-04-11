defmodule Tymeslot.Emails.EmailScheduler.AccountSchedulerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :unit

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Emails.EmailScheduler.AccountScheduler
  alias Tymeslot.Workers.EmailWorker

  describe "schedule_email_change_emails/3" do
    test "enqueues verification and notification jobs with correct args" do
      user = insert(:user)
      new_email = "new@example.com"
      verification_url = "https://example.com/verify/token123"

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 new_email,
                 verification_url
               )

      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 2

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_change_verification",
          "user_id" => user.id,
          "new_email" => new_email,
          "verification_url" => verification_url
        }
      )

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

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 new_email,
                 verification_url
               )

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 new_email,
                 verification_url
               )

      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 2
    end

    test "different new_email creates additional jobs" do
      user = insert(:user)
      verification_url = "https://example.com/verify/token123"

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 "first@example.com",
                 verification_url
               )

      assert :ok =
               AccountScheduler.schedule_email_change_emails(
                 user.id,
                 "second@example.com",
                 verification_url
               )

      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 4
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

    test "returns :ok" do
      user = insert(:user)

      result =
        AccountScheduler.schedule_email_change_confirmations(
          user.id,
          "old@example.com",
          "new@example.com"
        )

      assert result == :ok
    end

    test "enqueues exactly one job" do
      user = insert(:user)

      assert :ok =
               AccountScheduler.schedule_email_change_confirmations(
                 user.id,
                 "old@example.com",
                 "new@example.com"
               )

      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 1
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
