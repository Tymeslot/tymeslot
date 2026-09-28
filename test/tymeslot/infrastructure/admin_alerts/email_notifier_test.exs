defmodule Tymeslot.Infrastructure.AdminAlerts.EmailNotifierTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Repo
  alias Tymeslot.Test.LogCapture
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

  # SaaS forces the flag on and relies on ADMIN_ALERT_EMAIL; a self-hoster can
  # switch it on in the admin settings. Either way, an enabled flag with no
  # usable recipient drops every alert email, so each drop is logged at :error.
  describe "when feature flag is enabled but email is missing or invalid" do
    setup do
      setup_config(:tymeslot, admin_alerts_enabled: true)
    end

    for {label, recipient} <- [nil: nil, empty: "", malformed: "not-an-email"] do
      test "logs the dropped email at :error when admin_alert_email is #{label}" do
        with_config(:tymeslot, admin_alert_email: unquote(recipient))

        events =
          LogCapture.with_capture(fn ->
            assert :ok =
                     AdminAlerts.send_alert(:unhandled_webhook, %{
                       event_type: "charge.failed",
                       event_id: "evt_no_recipient_#{unquote(label)}"
                     })

            LogCapture.drain()
          end)

        assert all_enqueued(worker: EmailWorker) == []

        assert [%{level: :warning}] = logged(events, "ADMIN ALERT")
        assert [%{level: :error} = dropped] = logged(events, "no valid recipient")
        assert LogCapture.message_text(dropped.msg) =~ "ADMIN_ALERT_EMAIL"
        assert LogCapture.message_text(dropped.msg) =~ "Admin alert recipient"
      end
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
               AdminAlerts.report(:dispute_created,
                 summary: "New dispute created",
                 reason: {:dispute_created, "fraudulent"},
                 context: %{dispute_id: "dp_006"}
               )

      [job] = all_enqueued(worker: EmailWorker)
      assert job.args["message"] =~ "dp_006 (Reason: fraudulent)"
      assert job.args["message"] =~ "Manual review"
    end

    test "enqueued job carries the registry severity as a string" do
      assert :ok =
               AdminAlerts.send_alert(:dispute_lost, %{dispute_id: "dp_sev", user_id: 7})

      [job] = all_enqueued(worker: EmailWorker)
      assert job.args["severity"] == "error"
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

  # The headline is built from the alert's metadata, so it must be built from
  # the scrubbed copy: formatting first put the organiser's raw address into
  # the log line, the persisted job args and the alert email.
  describe "personal data in the alert headline" do
    setup do
      setup_config(:tymeslot,
        admin_alerts_enabled: true,
        admin_alert_email: "ops@example.com"
      )
    end

    test "a calendar sync error never carries the owner's raw address" do
      LogCapture.with_capture(fn ->
        assert :ok =
                 AdminAlerts.send_alert(:calendar_sync_error, %{
                   owner_email: "owner@example.com",
                   reason_message: "boom",
                   meeting_id: 1,
                   calendar_integration_id: 5
                 })
      end)

      log_event = LogCapture.await_log("ADMIN ALERT")
      refute inspect(log_event) =~ "owner@example.com"

      [job] = all_enqueued(worker: EmailWorker)
      refute Jason.encode!(job.args) =~ "owner@example.com"
      assert job.args["message"] == "Calendar sync error for o***@example.com: boom"
    end

    test "a rejected recipient's address in the provider reason is masked" do
      assert :ok =
               AdminAlerts.send_alert(:recipient_email_rejected, %{
                 summary: "Recipient permanently undeliverable, email discarded",
                 reason_message: "Found inactive addresses: jane.doe@example.com",
                 meeting_id: 7
               })

      [job] = all_enqueued(worker: EmailWorker)
      refute Jason.encode!(job.args) =~ "jane.doe@example.com"
      assert job.args["message"] =~ "Found inactive addresses: j***@example.com"
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

    # The key identifies the failing calendar, not its owner: one owner with
    # two broken calendars gets an alert for each.
    test "calendar sync errors from different calendars both enqueue" do
      for integration_id <- [1, 2] do
        assert :ok =
                 AdminAlerts.send_alert(:calendar_sync_error, %{
                   owner_email: "owner@example.com",
                   calendar_integration_id: integration_id,
                   meeting_id: integration_id,
                   reason_message: "boom"
                 })
      end

      assert length(all_enqueued(worker: EmailWorker)) == 2
    end

    test "repeat calendar sync errors from one calendar collapse into one alert" do
      for meeting_id <- [1, 2] do
        assert :ok =
                 AdminAlerts.send_alert(:calendar_sync_error, %{
                   owner_email: "owner@example.com",
                   calendar_integration_id: 5,
                   meeting_id: meeting_id,
                   reason_message: "boom"
                 })
      end

      assert length(all_enqueued(worker: EmailWorker)) == 1
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
    test "an error delivering an admin alert is logged but never enqueues another email" do
      assert :ok =
               AdminAlerts.send_alert(:new_error, %{
                 error_id: 12,
                 job_worker: "Tymeslot.Workers.EmailWorker",
                 job_action: "send_admin_alert"
               })

      assert :ok =
               AdminAlerts.send_alert(:error_regression, %{
                 error_id: 12,
                 occurrence_id: 40,
                 job_worker: "Tymeslot.Workers.EmailWorker",
                 job_action: "send_admin_alert"
               })

      assert all_enqueued(worker: EmailWorker) == []
    end

    test "an error in any other email the worker sends still enqueues an alert email" do
      assert :ok =
               AdminAlerts.send_alert(:new_error, %{
                 error_id: 13,
                 job_worker: "Tymeslot.Workers.EmailWorker",
                 job_action: "send_booking_confirmation"
               })

      assert [_job] = all_enqueued(worker: EmailWorker)
    end

    test "an error in any other worker still enqueues an alert email" do
      assert :ok =
               AdminAlerts.send_alert(:new_error, %{
                 error_id: 14,
                 job_worker: "Tymeslot.Workers.WebhookWorker",
                 job_action: "send_admin_alert"
               })

      assert [_job] = all_enqueued(worker: EmailWorker)
    end

    # The admin-alert email itself bouncing must not re-enqueue another
    # admin-alert email to the same dead recipient: that email would bounce
    # too, raising another :recipient_email_rejected report, forever. This is
    # the same feedback loop as the delivery error case above, just reached
    # through the recipient-rejected path instead of a recorded error.
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

  defp logged(events, text),
    do: Enum.filter(events, &(LogCapture.message_text(&1.msg) =~ text))
end
