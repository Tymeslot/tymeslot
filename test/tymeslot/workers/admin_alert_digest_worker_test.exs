defmodule Tymeslot.Workers.AdminAlertDigestWorkerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :emails

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Emails.EmailService
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.DigestEntrySchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.AdminAlertDigestWorker
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      admin_alerts_impl: Tymeslot.Infrastructure.AdminAlerts.EmailNotifier,
      admin_alerts_enabled: true,
      admin_alert_email: "ops@example.com"
    )
  end

  defp refund(user_id), do: AdminAlerts.send_alert(:refund_processed, refund_metadata(user_id))
  defp refund_metadata(user_id), do: %{user_id: user_id, total_refunded: 100}

  defp digest_jobs do
    Enum.filter(
      all_enqueued(worker: EmailWorker),
      &(&1.args["action"] == "send_admin_alert_digest")
    )
  end

  describe "with waiting entries" do
    test "hands one email carrying every entry to the email worker and empties the table" do
      refund(1)
      refund(2)
      refund(2)

      assert :ok = perform_job(AdminAlertDigestWorker, %{})

      assert [job] = digest_jobs()
      assert job.args["recipient"] == "ops@example.com"
      assert job.max_attempts == 20

      messages = Enum.map(job.args["entries"], & &1["message"])

      assert Enum.sort(messages) == [
               "Refund of 100 processed for user 1",
               "Refund of 100 processed for user 2"
             ]

      assert %{"occurrences" => 2} =
               Enum.find(job.args["entries"], &(&1["message"] =~ "user 2"))

      assert Repo.all(DigestEntrySchema) == []
    end

    test "the handed-off job delivers the digest email to the operator" do
      Application.put_env(:swoosh, :shared_test_process, self())
      on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)

      stub(EmailServiceMock, :send_admin_alert_digest, &EmailService.send_admin_alert_digest/2)

      refund(1)
      AdminAlerts.send_alert(:integration_health_recovery, %{summary: "Google sync recovered"})

      assert :ok = perform_job(AdminAlertDigestWorker, %{})
      [job] = digest_jobs()

      assert :ok = perform_job(EmailWorker, job.args)

      assert_received {:email, email}
      assert email.to == [{"Tymeslot Operator", "ops@example.com"}]
      assert email.subject == "[INFO] Tymeslot: daily digest (2 alerts)"
      assert email.text_body =~ "Refund of 100 processed for user 1"
      assert email.text_body =~ "Google sync recovered"
      assert email.html_body =~ "Google sync recovered"
    end

    test "a failed send retries the job, which still carries every entry" do
      expect(EmailServiceMock, :send_admin_alert_digest, fn _recipient, _digest ->
        {:error, "SMTP unavailable"}
      end)

      refund(1)
      assert :ok = perform_job(AdminAlertDigestWorker, %{})
      [job] = digest_jobs()

      assert {:error, _reason} = perform_job(EmailWorker, job.args)
      assert [%{"message" => "Refund of 100 processed for user 1"}] = job.args["entries"]

      # The digest retries on the admin alert schedule, not the five quick
      # attempts of an ordinary email.
      assert EmailWorker.backoff(%{job | attempt: 3}) == 240
    end
  end

  test "sends nothing when no entry is waiting" do
    assert :ok = perform_job(AdminAlertDigestWorker, %{})

    assert all_enqueued(worker: EmailWorker) == []
  end

  # A day with more distinct info alerts than one email should carry lists the
  # oldest and counts the rest by type, and the table is still emptied: it
  # stays bounded however many alerts arrive.
  test "caps the entries in one email and counts the rest by type" do
    for user_id <- 1..103, do: refund(user_id)
    AdminAlerts.send_alert(:integration_health_recovery, %{summary: "Recovered"})

    assert :ok = perform_job(AdminAlertDigestWorker, %{})

    [job] = digest_jobs()
    assert length(job.args["entries"]) == 100
    assert job.args["omitted"] == %{"integration_health_recovery" => 1, "refund_processed" => 3}
    assert Repo.all(DigestEntrySchema) == []
  end

  describe "gating" do
    test "drops waiting entries without an email once alerts are switched off" do
      refund(1)
      with_config(:tymeslot, admin_alerts_enabled: false)

      assert :ok = perform_job(AdminAlertDigestWorker, %{})

      assert all_enqueued(worker: EmailWorker) == []
      assert Repo.all(DigestEntrySchema) == []
    end

    test "keeps waiting entries while no valid recipient is configured" do
      refund(1)
      with_config(:tymeslot, admin_alert_email: "")

      assert :ok = perform_job(AdminAlertDigestWorker, %{})

      assert all_enqueued(worker: EmailWorker) == []
      assert [_entry] = Repo.all(DigestEntrySchema)
    end
  end
end
