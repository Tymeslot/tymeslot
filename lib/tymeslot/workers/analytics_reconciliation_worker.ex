defmodule Tymeslot.Workers.AnalyticsReconciliationWorker do
  @moduledoc """
  Runs `Tymeslot.Analytics.Reconciliation` on a daily cron schedule to
  cross-check page-view events against bookings and surface tracking errors
  (via structured logs always, and an admin alert when an invariant breaks).

  Runs in the dedicated `:monitoring` queue alongside the other health
  monitors. A no-op when booking analytics is disabled.
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3

  alias Tymeslot.Analytics.Reconciliation

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Reconciliation.run()
    :ok
  end
end
