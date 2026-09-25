defmodule Tymeslot.Workers.IntegrationHealthAlertWorker do
  @moduledoc """
  Hourly aggregate alerting on calendar integration health.

  Evaluates each signal in `Tymeslot.Integrations.HealthCheck.Alerting` (the
  number of organisers whose booking pages served no availability, and the
  rate of new `needs_reauth` flags) and raises an admin alert when one crosses
  its threshold, or a recovery alert when it drops back under. The thresholds
  and window are documented there.

  Runs on the dedicated `:monitoring` queue, like
  `Tymeslot.Workers.ObanQueueMonitorWorker`, so a backed-up
  `:calendar_integrations` queue cannot delay the alert about it.
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3

  require Logger

  alias Tymeslot.Integrations.HealthCheck.Alerting

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Enum.each(Alerting.signals(), &safe_check/1)
  end

  # One signal's failing query must not stop the others being evaluated.
  defp safe_check(signal) do
    Alerting.check_signal(signal)
  rescue
    error ->
      Logger.error("Integration health alert check failed",
        signal: signal,
        error: Exception.message(error)
      )
  end
end
