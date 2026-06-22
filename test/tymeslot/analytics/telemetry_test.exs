defmodule Tymeslot.Analytics.TelemetryTest do
  # async: false — telemetry handlers are global, process-wide state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :unit

  alias Tymeslot.Analytics.Telemetry

  describe "emit/1" do
    test "executes the page_view event tagged with the outcome" do
      test_pid = self()
      handler_id = "test-analytics-emit-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        Telemetry.event(),
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = Telemetry.emit(:filtered_rate_limit)

      assert_receive {:telemetry, [:tymeslot, :analytics, :page_view], %{count: 1},
                      %{outcome: :filtered_rate_limit}}
    end
  end

  describe "handle_event/4" do
    test "logs a warning for dropped or failed outcomes" do
      for outcome <- [:filtered_rate_limit, :error] do
        log =
          capture_log(fn ->
            Telemetry.handle_event(Telemetry.event(), %{count: 1}, %{outcome: outcome}, nil)
          end)

        assert log =~ "Booking analytics page view dropped: #{outcome}"
      end
    end

    test "stays silent for healthy outcomes" do
      for outcome <- [:ok, :filtered_bot, :disabled] do
        log =
          capture_log(fn ->
            Telemetry.handle_event(Telemetry.event(), %{count: 1}, %{outcome: outcome}, nil)
          end)

        assert log == ""
      end
    end
  end
end
