defmodule Tymeslot.Infrastructure.AdminAlerts.EmailNotifierDigestTest do
  # Info alerts wait for the daily digest instead of each sending an email.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.DigestEntrySchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.EmailWorker

  setup do
    setup_config(:tymeslot,
      admin_alerts_impl: Tymeslot.Infrastructure.AdminAlerts.EmailNotifier,
      admin_alerts_enabled: true,
      admin_alert_email: "ops@example.com"
    )
  end

  describe "an info alert" do
    test "creates a digest entry and enqueues no email" do
      assert :ok = AdminAlerts.send_alert(:refund_processed, %{user_id: 7, total_refunded: 100})

      assert all_enqueued(worker: EmailWorker) == []

      assert [entry] = Repo.all(DigestEntrySchema)
      assert entry.alert_type == "refund_processed"
      assert entry.category == "Payment"
      assert entry.message == "Refund of 100 processed for user 7"
      assert entry.occurrences == 1
      assert entry.metadata["user_id"] == 7
    end

    test "is still logged at once" do
      LogCapture.with_capture([logger_level: :info], fn ->
        AdminAlerts.send_alert(:refund_processed, %{user_id: 8, total_refunded: 50})
      end)

      assert %{level: :info} = LogCapture.await_log("ADMIN ALERT")
    end

    test "stores only scrubbed metadata" do
      assert :ok =
               AdminAlerts.send_alert(:integration_health_recovery, %{
                 summary: "Recovered for alice@example.com",
                 owner_email: "alice@example.com"
               })

      [entry] = Repo.all(DigestEntrySchema)
      refute inspect(entry) =~ "alice@example.com"
      assert entry.metadata["owner_email_masked"] == "a***@example.com"
      assert entry.message == "Recovered for a***@example.com"
    end
  end

  # An info alert the dedup key would suppress as an email collapses into the
  # entry already waiting, counting the repeat instead of adding a row.
  describe "deduplication" do
    test "an identical info alert raises the count of the waiting entry" do
      metadata = %{user_id: 9, total_refunded: 100}

      assert :ok = AdminAlerts.send_alert(:refund_processed, metadata)
      assert :ok = AdminAlerts.send_alert(:refund_processed, metadata)

      assert [%{occurrences: 2}] = Repo.all(DigestEntrySchema)
    end

    test "info alerts with different dedup keys stay separate entries" do
      assert :ok = AdminAlerts.send_alert(:refund_processed, %{user_id: 1, total_refunded: 1})
      assert :ok = AdminAlerts.send_alert(:refund_processed, %{user_id: 2, total_refunded: 1})

      assert length(Repo.all(DigestEntrySchema)) == 2
    end

    test "the key is the alert's dedup key, not its message" do
      # The recovery message embeds a live count; the dedup key does not.
      for count <- [3, 4] do
        assert :ok =
                 AdminAlerts.send_alert(:integration_health_recovery, %{
                   signal: "sync_failures",
                   incident_started_at: "2026-09-27T10:00:00Z",
                   summary: "#{count} integrations recovered"
                 })
      end

      assert [%{occurrences: 2, message: "4 integrations recovered"}] =
               Repo.all(DigestEntrySchema)
    end
  end

  describe "gating" do
    test "writes nothing when admin alerts are disabled" do
      with_config(:tymeslot, admin_alerts_enabled: false)

      assert :ok = AdminAlerts.send_alert(:refund_processed, %{user_id: 7, total_refunded: 1})

      assert Repo.all(DigestEntrySchema) == []
    end

    test "writes nothing when no valid recipient is configured" do
      with_config(:tymeslot, admin_alert_email: "not-an-email")

      assert :ok = AdminAlerts.send_alert(:refund_processed, %{user_id: 7, total_refunded: 1})

      assert Repo.all(DigestEntrySchema) == []
    end
  end

  test "a warning alert is still emailed at once" do
    assert :ok =
             AdminAlerts.send_alert(:unhandled_webhook, %{
               event_type: "charge.failed",
               event_id: "evt_digest_001"
             })

    assert [_job] = all_enqueued(worker: EmailWorker)
    assert Repo.all(DigestEntrySchema) == []
  end

  # The digest travels the same delivery path as an alert email, so a failure
  # delivering it must not raise an alert email that would fail the same way.
  test "an error or bounce delivering the digest never enqueues an alert email" do
    assert :ok =
             AdminAlerts.send_alert(:new_error, %{
               error_id: 21,
               job_worker: "Tymeslot.Workers.EmailWorker",
               job_action: "send_admin_alert_digest"
             })

    assert :ok =
             AdminAlerts.send_alert(:recipient_email_rejected, %{
               action: "send_admin_alert_digest",
               reason_message: "inactive"
             })

    assert all_enqueued(worker: EmailWorker) == []
  end
end
