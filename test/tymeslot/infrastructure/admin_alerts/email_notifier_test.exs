defmodule Tymeslot.Infrastructure.AdminAlerts.EmailNotifierTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup do
    # Force the EmailNotifier impl regardless of any env override
    setup_config(:tymeslot,
      admin_alerts_impl: Tymeslot.Infrastructure.AdminAlerts.EmailNotifier
    )

    Repo.delete_all(Oban.Job)

    :ok
  end

  describe "when feature flag is disabled (default)" do
    setup do
      setup_config(:tymeslot,
        admin_alerts_enabled: false,
        admin_alert_email: "ops@example.com"
      )
    end

    test "logs the alert but does not enqueue an email" do
      assert :ok =
               AdminAlerts.send_alert(:unhandled_webhook, %{
                 event_type: "charge.failed",
                 event_id: "evt_disabled_001"
               })

      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  describe "when feature flag is enabled but email is missing or invalid" do
    setup do
      setup_config(:tymeslot, admin_alerts_enabled: true)
    end

    test "does not enqueue when admin_alert_email is nil" do
      with_config(:tymeslot, admin_alert_email: nil)

      assert :ok =
               AdminAlerts.send_alert(:unhandled_webhook, %{
                 event_type: "charge.failed",
                 event_id: "evt_no_email_002"
               })

      assert all_enqueued(worker: EmailWorker) == []
    end

    test "does not enqueue when admin_alert_email is an empty string" do
      with_config(:tymeslot, admin_alert_email: "")

      assert :ok =
               AdminAlerts.send_alert(:unhandled_webhook, %{
                 event_type: "charge.failed",
                 event_id: "evt_empty_003"
               })

      assert all_enqueued(worker: EmailWorker) == []
    end

    test "does not enqueue when admin_alert_email is malformed" do
      with_config(:tymeslot, admin_alert_email: "not-an-email")

      assert :ok =
               AdminAlerts.send_alert(:unhandled_webhook, %{
                 event_type: "charge.failed",
                 event_id: "evt_malformed_004"
               })

      assert all_enqueued(worker: EmailWorker) == []
    end
  end

  describe "when feature flag is enabled and email is valid" do
    setup do
      setup_config(:tymeslot,
        admin_alerts_enabled: true,
        admin_alert_email: "ops@example.com"
      )
    end

    test "enqueues an EmailWorker job with the registry-derived category" do
      assert :ok =
               AdminAlerts.send_alert(:unhandled_webhook, %{
                 event_type: "charge.failed",
                 event_id: "evt_enq_005"
               })

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_admin_alert", "category" => "Webhook"}
      )
    end

    test "enqueued job carries the formatted message" do
      assert :ok =
               AdminAlerts.send_alert(:dispute_created, %{
                 dispute_id: "dp_006",
                 reason: "fraudulent"
               })

      [job] = all_enqueued(worker: EmailWorker)
      assert job.args["message"] =~ "dp_006"
      assert job.args["message"] =~ "fraudulent"
      assert job.args["message"] =~ "Manual review"
    end

    test "enqueued job carries the registry severity as a string" do
      assert :ok =
               AdminAlerts.send_alert(:refund_processed, %{user_id: 7, total_refunded: 100})

      [job] = all_enqueued(worker: EmailWorker)
      assert job.args["severity"] == "info"
    end

    test "metadata is enriched with deployment context" do
      assert :ok =
               AdminAlerts.send_alert(:unhandled_webhook, %{
                 event_type: "charge.failed",
                 event_id: "evt_enrich_007"
               })

      [job] = all_enqueued(worker: EmailWorker)
      metadata = job.args["metadata"]
      assert Map.has_key?(metadata, "tymeslot_version")
      assert Map.has_key?(metadata, "deployment_type")
      assert Map.has_key?(metadata, "hostname")
      assert Map.has_key?(metadata, "timestamp")
      # Caller-provided metadata is preserved
      assert metadata["event_id"] == "evt_enrich_007"
    end

    test "carries the recipient address from config" do
      with_config(:tymeslot, admin_alert_email: "alerts@example.org")

      assert :ok =
               AdminAlerts.send_alert(:unhandled_webhook, %{
                 event_type: "charge.failed",
                 event_id: "evt_recipient_008"
               })

      [job] = all_enqueued(worker: EmailWorker)
      assert job.args["recipient"] == "alerts@example.org"
    end
  end

  describe "deduplication" do
    setup do
      setup_config(:tymeslot,
        admin_alerts_enabled: true,
        admin_alert_email: "ops@example.com"
      )
    end

    test "Oban uniqueness drops identical alerts within the dedup window" do
      metadata = %{event_type: "charge.failed", event_id: "evt_dedup_009"}

      assert :ok = AdminAlerts.send_alert(:unhandled_webhook, metadata)
      assert length(all_enqueued(worker: EmailWorker)) == 1

      assert :ok = AdminAlerts.send_alert(:unhandled_webhook, metadata)
      assert length(all_enqueued(worker: EmailWorker)) == 1
    end

    test "different alert content with the same type still enqueues" do
      assert :ok =
               AdminAlerts.send_alert(:unhandled_webhook, %{
                 event_type: "charge.failed",
                 event_id: "evt_diff_a_010"
               })

      assert :ok =
               AdminAlerts.send_alert(:unhandled_webhook, %{
                 event_type: "invoice.paid",
                 event_id: "evt_diff_b_010"
               })

      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 2
    end
  end

  describe "unknown alert types" do
    setup do
      setup_config(:tymeslot,
        admin_alerts_enabled: true,
        admin_alert_email: "ops@example.com"
      )
    end

    test "fall back to General category and warning severity" do
      assert :ok = AdminAlerts.send_alert(:totally_new_thing_011, %{foo: "bar"})

      assert_enqueued(
        worker: EmailWorker,
        args: %{"category" => "General", "severity" => "warning"}
      )
    end
  end

  describe "valid_email?/1" do
    test "accepts well-formed email addresses" do
      assert AdminAlerts.valid_email?("foo@example.com")
      assert AdminAlerts.valid_email?("alice+tag@sub.example.org")
    end

    test "rejects nil, empty, and malformed values" do
      refute AdminAlerts.valid_email?(nil)
      refute AdminAlerts.valid_email?("")
      refute AdminAlerts.valid_email?("not-an-email")
      refute AdminAlerts.valid_email?("missing-at.com")
      refute AdminAlerts.valid_email?("missing-domain@")
      refute AdminAlerts.valid_email?(123)
    end
  end
end
