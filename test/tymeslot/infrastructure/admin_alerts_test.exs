defmodule Tymeslot.Infrastructure.AdminAlertsTest do
  use ExUnit.Case, async: false

  @moduletag :infrastructure
  @moduletag :unit

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes
  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber
  alias Tymeslot.Test.LogCapture

  defmodule TestNotifier do
    @behaviour Tymeslot.Infrastructure.AdminAlerts

    @impl Tymeslot.Infrastructure.AdminAlerts
    def send_alert(type, metadata) do
      send(self(), {:alert_sent, type, metadata})
      :ok
    end
  end

  setup do
    setup_config(:tymeslot, admin_alerts_impl: TestNotifier)
    :ok
  end

  describe "report/2" do
    test "raises KeyError when :summary is missing" do
      assert_raise KeyError, fn ->
        AdminAlerts.report(:calendar_sync_error, context: %{meeting_id: 1})
      end
    end

    test "delegates to send_alert/2 with summary merged in" do
      AdminAlerts.report(:calendar_sync_error,
        summary: "Sync failed",
        context: %{meeting_id: 42}
      )

      assert_received {:alert_sent, :calendar_sync_error, metadata}
      assert metadata.summary == "Sync failed"
      assert metadata.meeting_id == 42
    end

    test "omits reason keys when :reason is nil" do
      AdminAlerts.report(:calendar_sync_error,
        summary: "Sync failed",
        reason: nil,
        context: %{meeting_id: 42}
      )

      assert_received {:alert_sent, :calendar_sync_error, metadata}
      refute Map.has_key?(metadata, :reason_code)
      refute Map.has_key?(metadata, :reason_message)
    end

    test "omits reason keys when :reason is not passed at all" do
      AdminAlerts.report(:calendar_sync_error, summary: "Sync failed")

      assert_received {:alert_sent, :calendar_sync_error, metadata}
      refute Map.has_key?(metadata, :reason_code)
      refute Map.has_key?(metadata, :reason_message)
    end

    test "merges normalised reason as flat reason_code/reason_message keys" do
      AdminAlerts.report(:calendar_sync_error,
        summary: "Sync failed",
        reason: {:api_error, "invalid_grant"}
      )

      assert_received {:alert_sent, :calendar_sync_error, metadata}
      assert metadata.reason_code == :api_error
      assert metadata.reason_message == "invalid_grant"
    end

    test "empty :context still dispatches with summary present" do
      AdminAlerts.report(:calendar_sync_error, summary: "Sync failed")

      assert_received {:alert_sent, :calendar_sync_error, %{summary: "Sync failed"}}
    end

    test "context keys that collide with summary lose to the explicit summary" do
      AdminAlerts.report(:calendar_sync_error,
        summary: "Explicit summary",
        context: %{summary: "should be overridden"}
      )

      assert_received {:alert_sent, :calendar_sync_error, %{summary: "Explicit summary"}}
    end
  end

  describe "report/2 headlines" do
    setup :capture_admin_alerts

    test ":dispute_created shows the Stripe dispute reason" do
      AdminAlerts.report(:dispute_created,
        summary: "New dispute created",
        reason: {:dispute_created, "fraudulent"},
        context: %{dispute_id: "dp_1"}
      )

      assert_receive {:send_alert, :dispute_created, metadata}
      message = AlertTypes.format_message(:dispute_created, metadata)
      assert message =~ "dp_1 (Reason: fraudulent)"
    end

    test ":calendar_sync_error shows the sync failure reason" do
      AdminAlerts.report(:calendar_sync_error,
        summary: "Calendar sync failed for meeting",
        reason: {:api_error, "invalid_grant"},
        context: %{owner_email: "owner@example.com"}
      )

      assert_receive {:send_alert, :calendar_sync_error, metadata}
      message = AlertTypes.format_message(:calendar_sync_error, PIIScrubber.scrub(metadata))
      assert message == "Calendar sync error for o***@example.com: invalid_grant"
    end
  end

  describe "check_config/0" do
    for {label, recipient} <- [nil: nil, malformed: "not-an-email"] do
      test "logs one error naming the fix when enabled with a #{label} recipient" do
        with_config(:tymeslot, admin_alerts_enabled: true, admin_alert_email: unquote(recipient))

        assert [%{level: :error, msg: msg}] = check_config_events()
        assert LogCapture.message_text(msg) =~ "ADMIN_ALERT_EMAIL"
        assert LogCapture.message_text(msg) =~ "Admin alert recipient"
      end
    end

    test "logs nothing when alerts are disabled, even without a recipient" do
      with_config(:tymeslot, admin_alerts_enabled: false, admin_alert_email: nil)

      assert check_config_events() == []
    end

    test "logs nothing when enabled with a valid recipient" do
      with_config(:tymeslot, admin_alerts_enabled: true, admin_alert_email: "ops@example.com")

      assert check_config_events() == []
    end
  end

  defp check_config_events do
    LogCapture.with_capture(fn ->
      assert :ok = AdminAlerts.check_config()
      LogCapture.drain()
    end)
  end
end
