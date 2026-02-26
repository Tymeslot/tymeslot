defmodule Tymeslot.Infrastructure.ObanLogger do
  @moduledoc """
  Attaches a telemetry handler that sets Logger metadata for Oban job processes.

  Oban workers run in separate Erlang processes that lack the `correlation_id`
  and other tracing context set during HTTP request handling. This handler
  listens to `[:oban, :job, :start]` and generates a fresh `correlation_id`
  so every log line emitted during job execution is traceable.
  """

  alias Tymeslot.Infrastructure.CorrelationId

  require Logger

  @handler_id "tymeslot-oban-logger-metadata"

  @doc """
  Attaches the telemetry handler. Call once during application startup.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach(
      @handler_id,
      [:oban, :job, :start],
      &__MODULE__.handle_event/4,
      []
    )
  end

  @doc false
  @spec handle_event([atom()], map(), map(), any()) :: :ok
  def handle_event([:oban, :job, :start], _measurements, _metadata, _config) do
    correlation_id = CorrelationId.generate()
    CorrelationId.put_in_process(correlation_id)
    CorrelationId.add_to_logger_metadata(correlation_id)
    :ok
  rescue
    exception ->
      Logger.error("ObanLogger metadata handler failed",
        error: Exception.message(exception)
      )

      :ok
  end
end
