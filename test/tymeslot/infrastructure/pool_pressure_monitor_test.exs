defmodule Tymeslot.Infrastructure.PoolPressureMonitorTest do
  # async: false: the admin alert implementation is global application env,
  # and the monitor listens to the repo's global query telemetry.
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  import Tymeslot.AdminAlertsCaptureHelpers

  alias Tymeslot.Infrastructure.PoolPressureMonitor

  setup :capture_admin_alerts

  @query_event [:tymeslot, :repo, :query]

  # The application does not start the monitor in test, so each test starts
  # its own under the default name.
  defp start_monitor(opts \\ []) do
    opts =
      Keyword.merge(
        [repos: [Tymeslot.Repo], threshold_ms: 500, limit: 3, window_ms: :manual],
        opts
      )

    start_supervised!({PoolPressureMonitor, opts})
    PoolPressureMonitor
  end

  defp query(queue_time_ms) do
    queue_time =
      if queue_time_ms, do: System.convert_time_unit(queue_time_ms, :millisecond, :native)

    :telemetry.execute(@query_event, %{queue_time: queue_time, total_time: 1}, %{
      repo: Tymeslot.Repo
    })
  end

  test "enough slow checkouts in one window raise exactly one alert" do
    monitor = start_monitor()

    Enum.each(1..5, fn _n -> query(750) end)
    PoolPressureMonitor.evaluate(monitor)

    assert_receive {:send_alert, :database_pool_pressure, payload}
    assert payload.repo == "Tymeslot.Repo"
    assert payload.slow_checkouts == 5
    assert payload.threshold_ms == 500
    refute_receive {:send_alert, :database_pool_pressure, _payload}, 50
  end

  test "each window is counted afresh" do
    monitor = start_monitor()

    Enum.each(1..3, fn _n -> query(750) end)
    PoolPressureMonitor.evaluate(monitor)
    assert_receive {:send_alert, :database_pool_pressure, %{slow_checkouts: 3}}

    # The next window starts from zero, so two slow checkouts stay quiet.
    Enum.each(1..2, fn _n -> query(750) end)
    PoolPressureMonitor.evaluate(monitor)
    refute_receive {:send_alert, :database_pool_pressure, _payload}, 50
  end

  test "fast queries and queries without a queue time are not counted" do
    monitor = start_monitor()

    Enum.each(1..10, fn _n -> query(100) end)
    Enum.each(1..10, fn _n -> query(nil) end)
    query(750)
    query(750)
    PoolPressureMonitor.evaluate(monitor)

    refute_receive {:send_alert, :database_pool_pressure, _payload}, 50
  end

  test "a repo outside the configured list is not watched" do
    monitor = start_monitor(repos: [])

    Enum.each(1..5, fn _n -> query(750) end)
    PoolPressureMonitor.evaluate(monitor)

    refute_receive {:send_alert, :database_pool_pressure, _payload}, 50
  end

  test "the handler survives a malformed event" do
    monitor = start_monitor()

    :telemetry.execute(@query_event, %{queue_time: "soon"}, %{})
    :telemetry.execute(@query_event, %{}, %{})
    Enum.each(1..3, fn _n -> query(750) end)
    PoolPressureMonitor.evaluate(monitor)

    assert_receive {:send_alert, :database_pool_pressure, %{slow_checkouts: 3}}
  end
end
