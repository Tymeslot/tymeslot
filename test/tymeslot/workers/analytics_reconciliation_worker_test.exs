defmodule Tymeslot.Workers.AnalyticsReconciliationWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :analytics
  @moduletag :database

  alias Tymeslot.Workers.AnalyticsReconciliationWorker

  test "perform/1 runs reconciliation and returns :ok" do
    assert :ok = AnalyticsReconciliationWorker.perform(%Oban.Job{args: %{}})
  end
end
