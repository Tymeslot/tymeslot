defmodule Tymeslot.Infrastructure.ObanLogger do
  @moduledoc """
  Owns structured logging for Oban *job* telemetry events.

  Oban's own `attach_default_logger/1` has two shortcomings for our needs:

    * it logs every event — including `job:exception` — at a single level
      (`:info` by default), so failures and discards are buried among routine
      job logs; and
    * it cannot guarantee a `correlation_id` is attached, because `:telemetry`
      does not order handlers, so a separate metadata-setting handler may run
      *after* the default logger has already emitted `job:start`.

  This module instead owns the three job events directly. A single handler sets
  a fresh `correlation_id` at job start (so every subsequent log line in the job
  process is traceable, including the start line itself) and emits each event,
  logging `job:exception` at `:warning` while the job can still retry and at
  `:error` once it reaches a terminal state.

  The non-job events (plugin, notifier, peer, queue, stager) are still handled by
  Oban's default logger — see `Tymeslot.Application`.
  """

  alias Tymeslot.Infrastructure.CorrelationId

  require Logger

  @handler_id "tymeslot-oban-job-logger"

  @job_events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]

  @detail_keys [:attempt, :args, :id, :max_attempts, :meta, :queue, :tags, :worker]

  @doc """
  Attaches the telemetry handler for Oban job events. Call once during startup.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler_id, @job_events, &__MODULE__.handle_event/4, [])
  end

  @doc false
  @spec handle_event([atom()], map(), map(), any()) :: :ok
  def handle_event([:oban, :job, event], measurements, metadata, _config) do
    do_handle(event, measurements, metadata)
  rescue
    exception ->
      Logger.error("ObanLogger job handler failed",
        error: Exception.message(exception)
      )

      :ok
  end

  defp do_handle(:start, measurements, metadata) do
    correlation_id = CorrelationId.generate()
    CorrelationId.put_in_process(correlation_id)
    CorrelationId.add_to_logger_metadata(correlation_id)

    log_job_event(:info, "job:start", metadata, %{
      system_time: Map.get(measurements, :system_time)
    })
  end

  defp do_handle(:stop, measurements, metadata) do
    log_job_event(:info, "job:stop", metadata, %{
      duration: convert(measurements[:duration]),
      queue_time: convert(measurements[:queue_time]),
      state: metadata[:state]
    })
  end

  defp do_handle(:exception, measurements, metadata) do
    log_job_event(exception_level(metadata[:state]), "job:exception", metadata, %{
      duration: convert(measurements[:duration]),
      queue_time: convert(measurements[:queue_time]),
      state: metadata[:state],
      error:
        Exception.format_banner(metadata[:kind], metadata[:reason], metadata[:stacktrace] || [])
    })
  end

  # A job that can still retry logs at :warning; a terminal failure (discarded,
  # cancelled) logs at :error so it stands out and can be alerted on.
  defp exception_level(:failure), do: :warning
  defp exception_level(_state), do: :error

  defp log_job_event(level, event, metadata, extra) do
    Logger.log(
      level,
      fn ->
        metadata
        |> Map.get(:job, %{})
        |> Map.take(@detail_keys)
        |> Map.merge(extra)
        |> Map.put(:event, event)
        |> Map.put(:source, "oban")
      end,
      domain: [:oban]
    )
  end

  defp convert(nil), do: nil
  defp convert(value), do: System.convert_time_unit(value, :native, :microsecond)
end
