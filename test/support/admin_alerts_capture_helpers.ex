defmodule Tymeslot.AdminAlertsCaptureHelpers do
  @moduledoc """
  Test helpers for capturing admin alerts raised from out-of-process callers.

  `CrashReporter` (a Logger handler) and `ObanFailureAlerter` (a telemetry
  handler) both raise admin alerts from processes other than the test process,
  so `send(self(), …)` from the notifier cannot reach the test. This helper
  installs a notifier that forwards every alert to a pid stored in application
  env, and a setup that points that pid at the calling test process.

  ## Usage

      import Tymeslot.AdminAlertsCaptureHelpers

      setup :capture_admin_alerts

      test "raises an alert" do
        # trigger code under test
        assert_receive {:send_alert, :some_event, %{} = payload}
      end
  """

  import Tymeslot.ConfigTestHelpers

  defmodule TestNotifier do
    @moduledoc false
    @behaviour Tymeslot.Infrastructure.AdminAlerts

    @impl Tymeslot.Infrastructure.AdminAlerts
    def send_alert(event_type, payload) do
      pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)
      send(pid, {:send_alert, event_type, payload})
      :ok
    end
  end

  @doc """
  Setup callback that captures admin alerts into the current test process.

  Configures the admin alerts implementation to `TestNotifier` and stores the
  test pid so out-of-process callers can deliver alerts back to the test.
  Both config values are restored automatically on test exit.
  """
  @spec capture_admin_alerts(map()) :: :ok
  def capture_admin_alerts(_context \\ %{}) do
    setup_config(:tymeslot,
      admin_alerts_impl: TestNotifier,
      admin_alerts_test_pid: self()
    )
  end
end
