defmodule Tymeslot.Emails.AccountDeletionNoticeDeliveryTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :auth

  import Mox

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Emails.EmailService.AuthEmails
  alias Tymeslot.Notifications.Email.AuthEmails, as: AuthEmailHandlers

  setup :verify_on_exit!

  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    :ok
  end

  @details %{
    email: "ada@example.com",
    name: "Ada",
    locale: "en",
    scheduled_at: ~U[2026-10-16 09:00:00Z],
    restorable: true,
    timezone: "Europe/Tallinn"
  }

  test "the job carries the recipient, never the user id" do
    assert {:ok, :scheduled} = EmailScheduler.schedule_account_deletion_notice(@details)

    assert [job] = all_enqueued(worker: Tymeslot.Workers.EmailWorker)
    assert job.args["action"] == "send_account_deletion_notice"
    assert job.args["email"] == "ada@example.com"
    assert job.args["restorable"] == true
    assert job.args["timezone"] == "Europe/Tallinn"
    refute Map.has_key?(job.args, "user_id")
  end

  test "the handler sends a restorable notice with the sign-in link" do
    expect(Tymeslot.EmailServiceMock, :send_account_deletion_notice, fn recipient, at, url ->
      assert recipient.email == "ada@example.com"
      assert recipient.timezone == "Europe/Tallinn"
      assert at == ~U[2026-10-16 09:00:00Z]
      assert url =~ "/auth/login"
      {:ok, :sent}
    end)

    args = %{
      "email" => "ada@example.com",
      "name" => "Ada",
      "locale" => "en",
      "scheduled_at" => "2026-10-16T09:00:00Z",
      "restorable" => true,
      "timezone" => "Europe/Tallinn"
    }

    assert AuthEmailHandlers.handle_account_deletion_notice(args) == :ok
  end

  test "the handler sends no restore link for an immediate deletion" do
    expect(Tymeslot.EmailServiceMock, :send_account_deletion_notice, fn _recipient, _at, url ->
      assert url == nil
      {:ok, :sent}
    end)

    args = %{
      "email" => "ada@example.com",
      "name" => "Ada",
      "locale" => "en",
      "scheduled_at" => "2026-10-16T09:00:00Z",
      "restorable" => false
    }

    assert AuthEmailHandlers.handle_account_deletion_notice(args) == :ok
  end

  test "the service delivers to the recipient with a subject that matches the variant" do
    recipient = %{email: "ada@example.com", name: "Ada", locale: "en", id: nil}

    assert {:ok, _result} =
             AuthEmails.send_account_deletion_notice(recipient, ~U[2026-10-16 09:00:00Z], nil)

    assert_received {:email, email}
    assert email.to == [{"Ada", "ada@example.com"}]
    assert email.subject == "Your Tymeslot account has been deleted"

    assert {:ok, _result} =
             AuthEmails.send_account_deletion_notice(
               recipient,
               ~U[2026-10-16 09:00:00Z],
               "https://example.com/auth/login"
             )

    assert_received {:email, scheduled}
    assert scheduled.subject == "Your Tymeslot account is scheduled for deletion"
  end
end
