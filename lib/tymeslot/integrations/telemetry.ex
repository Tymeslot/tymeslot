defmodule Tymeslot.Integrations.Telemetry do
  @moduledoc """
  Telemetry instrumentation for integration operations.

  This module provides:
  - Telemetry event definitions for integration operations
  - Structured logging with correlation IDs
  """

  require Logger

  @doc """
  List of all telemetry events emitted by the integrations system.
  """
  @spec events() :: [[atom()]]
  def events do
    [
      # Health checks
      [:tymeslot, :integration, :health_check]
    ]
  end

  @doc """
  Attaches default handlers for logging telemetry events.
  """
  @spec attach_default_handlers() :: :ok | {:error, :already_exists}
  def attach_default_handlers do
    :telemetry.attach_many(
      "tymeslot-integration-logger",
      events(),
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc """
  Public handler for telemetry events.
  Used by the telemetry system via module-qualified function reference.
  """
  @spec handle_event([atom()], map(), map(), any()) :: :ok
  def handle_event(event, measurements, metadata, _config) do
    log_level = determine_log_level(event, metadata)

    Logger.log(
      log_level,
      fn ->
        format_log_message(event, measurements, metadata)
      end,
      metadata
    )

    :ok
  end

  defp determine_log_level([:tymeslot, :integration, :health_check], metadata)
       when metadata.success == false do
    :warning
  end

  defp determine_log_level(_event, _metadata), do: :debug

  defp format_log_message(event, measurements, metadata) do
    event_name = Enum.join(event, ".")
    base_message = format_event_message(event, measurements, metadata, event_name)

    context = format_metadata(metadata)

    if map_size(context) > 0 do
      "#{base_message} | #{inspect(context)}"
    else
      base_message
    end
  end

  defp format_event_message(
         [:tymeslot, :integration, :health_check],
         measurements,
         metadata,
         _event_name
       ) do
    status = if metadata.success, do: "healthy", else: "unhealthy"
    "Health check: #{metadata.provider} - #{status} (#{measurements.duration}ms)"
  end

  defp format_event_message(_event, _measurements, _metadata, event_name) do
    "Event: #{event_name}"
  end

  defp format_metadata(metadata) do
    Enum.into(
      Enum.filter(Map.drop(metadata, [:correlation_id, :operation, :provider]), fn {_key, v} ->
        v != nil
      end),
      %{}
    )
  end
end
