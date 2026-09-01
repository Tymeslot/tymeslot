defmodule Tymeslot.Infrastructure.AdminAlerts.EmailNotifierTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Endpoint

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

    test "deployment context names the domain the instance serves" do
      assert :ok =
               AdminAlerts.send_alert(:unhandled_webhook, %{
                 event_type: "charge.failed",
                 event_id: "evt_domain_009"
               })

      [job] = all_enqueued(worker: EmailWorker)
      assert job.args["metadata"]["domain"] == Endpoint.host()
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

    test "masks denylisted PII keys in metadata before enqueuing" do
      assert :ok =
               AdminAlerts.send_alert(:calendar_sync_error, %{
                 owner_email: "alice@example.com",
                 meeting_id: 99
               })

      [job] = all_enqueued(worker: EmailWorker)
      metadata = job.args["metadata"]

      refute Map.has_key?(metadata, "owner_email")
      assert metadata["owner_email_masked"] == "a***@example.com"
      assert metadata["meeting_id"] == 99
    end

    test "masks embedded email addresses in free-form string fields" do
      assert :ok =
               AdminAlerts.send_alert(:calendar_sync_error, %{
                 summary: "User alice@example.com failed",
                 meeting_id: 99
               })

      [job] = all_enqueued(worker: EmailWorker)
      assert job.args["metadata"]["summary"] == "User a***@example.com failed"
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

  describe "alerts reporting a failure of the email pipeline itself" do
    setup do
      setup_config(:tymeslot,
        admin_alerts_enabled: true,
        admin_alert_email: "ops@example.com"
      )
    end

    # Enqueuing this alert is a feedback loop: the alert job fails for the same
    # reason the original did, its discard raises another alert, and so on. One
    # suppressed recipient once produced eighteen jobs and eighty-three failed
    # attempts this way.
    test "an EmailWorker failure is logged but never enqueues another email" do
      assert :ok =
               AdminAlerts.send_alert(:oban_job_failure, %{
                 worker: "Tymeslot.Workers.EmailWorker",
                 queue: "emails",
                 job_id: 393_245
               })

      assert all_enqueued(worker: EmailWorker) == []
    end

    test "a failure in any other worker still enqueues an alert email" do
      assert :ok =
               AdminAlerts.send_alert(:oban_job_failure, %{
                 worker: "Tymeslot.Workers.WebhookWorker",
                 queue: "webhooks",
                 job_id: 393_246
               })

      assert [_job] = all_enqueued(worker: EmailWorker)
    end

    # The admin-alert email itself bouncing must not re-enqueue another
    # admin-alert email to the same dead recipient: that email would bounce
    # too, raising another :recipient_email_rejected report, forever. This is
    # the same feedback loop as the EmailWorker case above, just reached
    # through the recipient-rejected path instead of a permanent job failure.
    test "a rejected admin-alert recipient is logged but never enqueues another email" do
      assert :ok =
               AdminAlerts.send_alert(:recipient_email_rejected, %{
                 action: "send_admin_alert",
                 reason_message: "ops@example.com is inactive"
               })

      assert all_enqueued(worker: EmailWorker) == []
    end

    test "a rejected recipient for an ordinary transactional email still enqueues an alert" do
      assert :ok =
               AdminAlerts.send_alert(:recipient_email_rejected, %{
                 action: "send_booking_confirmation",
                 meeting_id: 42
               })

      assert [_job] = all_enqueued(worker: EmailWorker)
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
