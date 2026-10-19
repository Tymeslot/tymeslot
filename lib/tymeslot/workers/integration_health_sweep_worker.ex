defmodule Tymeslot.Workers.IntegrationHealthSweepWorker do
  @moduledoc """
  Runs the integration health sweep every five minutes from the crontab:
  `Tymeslot.Integrations.HealthCheck.Scheduler.schedule_all/1` enqueues a
  check for each integration whose backoff has elapsed.

  Five minutes is the shortest backoff a check can be given, so the sweep
  honours the backoff ramp as written. Run from the crontab rather than a
  timer in each node, one sweep runs however many nodes there are.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    # Below the five-minute crontab interval: uniqueness counts from the
    # previous job's insertion, so a full 300 would swallow the next slot's
    # job whenever the cron plugin inserts it a moment early.
    unique: [period: 240]

  alias Tymeslot.Integrations.HealthCheck.Scheduler

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: Scheduler.schedule_all()
end
