defmodule Tymeslot.Workers.AnalyticsReconciliationWorkerTest do
  # async: false: :booking_analytics_enabled gates event emission on the public scheduling
  # routes, which the booking tests exercise throughout.
  use Tymeslot.DataCase, async: false

  @moduletag :analytics
  @moduletag :database

  alias Oban.Cron.Expression
  alias Tymeslot.Infrastructure.ObanCron
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

  # The cron service is off in test, so a typo in the schedule string or worker
  # module would otherwise ship silently. Guard it by asserting the worker is
  # in the shared crontab with a schedule Oban can actually parse.
  test "is registered in the shared crontab with a parseable schedule" do
    assert {schedule, AnalyticsReconciliationWorker} =
             List.keyfind(ObanCron.base_crontab(), AnalyticsReconciliationWorker, 1)

    assert {:ok, _expression} = Expression.parse(schedule)
  end
end
