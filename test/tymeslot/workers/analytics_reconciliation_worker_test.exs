defmodule Tymeslot.Workers.AnalyticsReconciliationWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :analytics
  @moduletag :database

  alias Oban.Cron.Expression
  alias Tymeslot.Workers.AnalyticsReconciliationWorker

  test "perform/1 discards the {:ok, _} result and returns :ok regardless" do
    # The worker intentionally ignores the return value of Reconciliation.run/0
    # (fire-and-forget on the result).  Both the disabled path ({:ok, :disabled})
    # and the enabled path ({:ok, %{...}}) must yield :ok from perform/1.
    original_flag = Application.get_env(:tymeslot, :booking_analytics_enabled)

    on_exit(fn ->
      if original_flag != nil do
        Application.put_env(:tymeslot, :booking_analytics_enabled, original_flag)
      else
        Application.delete_env(:tymeslot, :booking_analytics_enabled)
      end
    end)

    # Disabled path
    Application.put_env(:tymeslot, :booking_analytics_enabled, false)
    assert :ok = AnalyticsReconciliationWorker.perform(%Oban.Job{args: %{}})

    # Enabled path — with an empty DB, reconciliation completes successfully
    Application.put_env(:tymeslot, :booking_analytics_enabled, true)
    assert :ok = AnalyticsReconciliationWorker.perform(%Oban.Job{args: %{}})
  end

  # The crontab is only assembled in runtime.exs (prod) and never loaded in
  # test, so a typo in the schedule string or worker module would otherwise ship
  # silently. Guard it by asserting the worker is registered in runtime.exs with
  # a schedule Oban can actually parse.
  test "is registered in the runtime crontab with a parseable schedule" do
    runtime_exs =
      [__DIR__, "..", "..", "..", "config", "runtime.exs"]
      |> Path.join()
      |> Path.expand()
      |> File.read!()

    pattern =
      ~r/\{\s*"([^"]+)"\s*,\s*Tymeslot\.Workers\.AnalyticsReconciliationWorker\s*\}/

    assert [_match, schedule] = Regex.run(pattern, runtime_exs),
           "AnalyticsReconciliationWorker is not registered in the runtime.exs crontab"

    assert {:ok, _expression} = Expression.parse(schedule)
  end
end
