defmodule Tymeslot.Infrastructure.ObanFailureAlerter do
  @moduledoc """
  Telemetry handler that raises an admin alert when an Oban job fails *permanently*.

  Oban emits `[:oban, :job, :exception]` on every failed attempt, with
  `meta.state` set to `:failure` while retries remain and to `:discard` once the
  job has exhausted its attempts. Only the terminal `:discard` case alerts —
  retryable failures are expected to recover and would otherwise be noise.

  Intentional discards returned by a worker (`{:discard, reason}`) emit
  `job:stop`, not `job:exception`, so they never reach this handler — only
  genuine unhandled failures that ran out of retries do.

  Without this, a crashing worker only produced log lines; nothing surfaced the
  failure to an operator.
  """

  alias Tymeslot.Infrastructure.AdminAlerts

  require Logger

  @handler_id "tymeslot-oban-failure-alerter"

  @doc """
  Attaches the telemetry handler for terminal Oban job failures. Call once during
  startup.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach(
      @handler_id,
      [:oban, :job, :exception],
      &__MODULE__.handle_event/4,
      []
    )
  end

  @doc false
  @spec handle_event([atom()], map(), map(), any()) :: :ok
  def handle_event(
        [:oban, :job, :exception],
        _measurements,
        %{state: :discard} = metadata,
        _config
      ) do
    report_failure(metadata)
    :ok
  rescue
    exception ->
      Logger.error("ObanFailureAlerter handler failed",
        error: Exception.message(exception)
      )

      :ok
  end

  def handle_event([:oban, :job, :exception], _measurements, _metadata, _config), do: :ok

  defp report_failure(metadata) do
    job = metadata[:job] || %{}

    AdminAlerts.report(:oban_job_failure,
      summary: "Oban job failed permanently after exhausting retries",
      reason: metadata[:reason],
      context: %{
        worker: Map.get(job, :worker),
        queue: Map.get(job, :queue),
        job_id: Map.get(job, :id),
        attempt: Map.get(job, :attempt),
        max_attempts: Map.get(job, :max_attempts)
      }
    )
  end
end
