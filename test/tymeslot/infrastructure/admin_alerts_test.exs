defmodule Tymeslot.Infrastructure.AdminAlertsTest do
  use ExUnit.Case, async: false

  @moduletag :infrastructure
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Infrastructure.AdminAlerts

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
end
