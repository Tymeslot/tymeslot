defmodule Tymeslot.Infrastructure.Metrics do
  @moduledoc """
  Metrics collection for monitoring calendar operations and performance.
  Uses Telemetry for event emission.
  """

  require Logger

  @doc """
  Emits a calendar operation metric.
  """
  @spec emit_calendar_operation(atom(), map(), map()) :: :ok
  def emit_calendar_operation(operation, metadata \\ %{}, measurements \\ %{}) do
    :telemetry.execute(
      [:tymeslot, :calendar, operation],
      measurements,
      metadata
    )
  end

  @doc """
  Times and tracks a calendar operation.
  """
  @spec time_operation(atom(), map(), (-> term())) :: term()
  def time_operation(operation, metadata \\ %{}, fun) when is_function(fun, 0) do
    start_time = System.monotonic_time()

    try do
      result = fun.()

      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      emit_calendar_operation(
        operation,
        Map.merge(metadata, %{status: :success}),
        %{duration: duration_ms}
      )

      result
    rescue
      error ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        emit_calendar_operation(
          operation,
          Map.merge(metadata, %{status: :error, error: inspect(error)}),
          %{duration: duration_ms}
        )

        reraise error, __STACKTRACE__
    end
  end

  @doc """
  Tracks HTTP request metrics.
  """
  @spec track_http_request(String.t(), String.t(), integer(), number()) :: :ok
  def track_http_request(method, url, status_code, duration_ms) do
    :telemetry.execute(
      [:tymeslot, :http, :request],
      %{duration: duration_ms},
      %{
        method: method,
        url: sanitize_url(url),
        status_code: status_code
      }
    )
  end

  @doc """
  Tracks circuit breaker state changes.
  """
  @spec track_circuit_breaker_state(any(), atom(), atom()) :: :ok
  def track_circuit_breaker_state(breaker_name, old_state, new_state) do
    :telemetry.execute(
      [:tymeslot, :circuit_breaker, :state_change],
      %{},
      %{
        breaker: breaker_name,
        old_state: old_state,
        new_state: new_state
      }
    )
  end

  @doc """
  Tracks connection pool usage.
  """
  @spec track_pool_usage(atom(), keyword()) :: :ok
  def track_pool_usage(pool_name, stats) do
    :telemetry.execute(
      [:tymeslot, :connection_pool, :usage],
      %{
        in_use: stats[:in_use_count] || 0,
        free: stats[:free_count] || 0,
        queue: stats[:queue_count] || 0
      },
      %{pool: pool_name}
    )
  end

  @doc """
  Tracks parsing performance.
  """
  @spec track_parsing_performance(atom(), integer(), number(), integer()) :: :ok
  def track_parsing_performance(parser_type, size, duration_ms, event_count) do
    :telemetry.execute(
      [:tymeslot, :parser, :performance],
      %{
        duration: duration_ms,
        size: size,
        event_count: event_count,
        events_per_second: calculate_events_per_second(event_count, duration_ms)
      },
      %{parser: parser_type}
    )
  end

  @doc """
  Sets up default Telemetry handlers for logging metrics.
  """
  @spec setup_handlers() :: :ok
  def setup_handlers do
    handlers = [
      {
        [:tymeslot, :calendar, :list_events],
        &__MODULE__.handle_calendar_event/4
      },
      {
        [:tymeslot, :calendar, :create_event],
        &__MODULE__.handle_calendar_event/4
      },
      {
        [:tymeslot, :calendar, :update_event],
        &__MODULE__.handle_calendar_event/4
      },
      {
        [:tymeslot, :calendar, :delete_event],
        &__MODULE__.handle_calendar_event/4
      },
      {
        [:tymeslot, :http, :request],
        &__MODULE__.handle_http_event/4
      },
      {
        [:tymeslot, :circuit_breaker, :state_change],
        &__MODULE__.handle_circuit_breaker_event/4
      },
      {
        [:tymeslot, :connection_pool, :usage],
        &__MODULE__.handle_pool_event/4
      },
      {
        [:tymeslot, :parser, :performance],
        &__MODULE__.handle_parser_event/4
      }
    ]

    Enum.each(handlers, fn {event, handler} ->
      :telemetry.attach(
        "#{inspect(event)}-handler",
        event,
        handler,
        nil
      )
    end)

    :ok
  end

  # Telemetry measurement and metadata types

  @typep calendar_measurements :: %{optional(:duration) => number()}
  @typep calendar_metadata :: %{optional(:status) => atom(), optional(:error) => String.t()}

  @typep http_measurements :: %{optional(:duration) => number()}
  @typep http_metadata :: %{
           optional(:status_code) => integer(),
           optional(:method) => String.t(),
           optional(:url) => String.t()
         }

  @typep circuit_breaker_measurements :: %{}
  @typep circuit_breaker_metadata :: %{
           optional(:breaker) => any(),
           optional(:old_state) => atom(),
           optional(:new_state) => atom()
         }

  @typep pool_measurements :: %{
           optional(:queue) => non_neg_integer(),
           optional(:free) => non_neg_integer(),
           optional(:in_use) => non_neg_integer()
         }
  @typep pool_metadata :: %{optional(:pool) => atom()}

  @typep parser_measurements :: %{
           optional(:duration) => number(),
           optional(:size) => integer(),
           optional(:event_count) => integer()
         }
  @typep parser_metadata :: %{optional(:parser) => atom()}

  # Private functions

  defp sanitize_url(url) when is_binary(url) do
    # Remove sensitive information from URLs
    url
    |> URI.parse()
    |> Map.put(:userinfo, nil)
    |> URI.to_string()
  end

  defp sanitize_url(url), do: inspect(url)

  defp calculate_events_per_second(0, _duration_ms), do: 0.0
  defp calculate_events_per_second(_event_count, 0), do: 0.0

  defp calculate_events_per_second(event_count, duration_ms) do
    Float.round(event_count * 1000 / duration_ms, 2)
  end

  # Telemetry handlers

  @spec handle_calendar_event(list(atom()), calendar_measurements(), calendar_metadata(), term()) ::
          :ok
  def handle_calendar_event(event_name, measurements, metadata, _config) do
    operation = List.last(event_name)

    Logger.info("Calendar operation completed",
      operation: operation,
      duration_ms: measurements[:duration],
      status: metadata[:status]
    )

    if metadata[:status] == :error do
      Logger.error("Calendar operation failed",
        operation: operation,
        error: metadata[:error]
      )
    end
  end

  @spec handle_http_event(list(atom()), http_measurements(), http_metadata(), term()) :: :ok
  def handle_http_event(_event_name, measurements, metadata, _config) do
    # Only log errors or slow requests
    if metadata[:status_code] >= 400 or measurements[:duration] > 5000 do
      %{host: host, path: path} = request_target(metadata[:url])

      # Log host and path only — the query string carries calendar ids and
      # time-range parameters that are noisy and needlessly identifying.
      Logger.warning("HTTP request issue",
        method: metadata[:method],
        host: host,
        path: path,
        status_code: metadata[:status_code],
        duration_ms: measurements[:duration]
      )
    end
  end

  defp request_target(url) when is_binary(url) do
    uri = URI.parse(url)
    %{host: uri.host, path: uri.path}
  end

  defp request_target(_url), do: %{host: nil, path: nil}

  @spec handle_circuit_breaker_event(
          list(atom()),
          circuit_breaker_measurements(),
          circuit_breaker_metadata(),
          term()
        ) :: :ok
  def handle_circuit_breaker_event(_event_name, _measurements, metadata, _config) do
    Logger.warning("Circuit breaker state changed",
      breaker: metadata[:breaker],
      old_state: metadata[:old_state],
      new_state: metadata[:new_state]
    )
  end

  @spec handle_pool_event(list(atom()), pool_measurements(), pool_metadata(), term()) :: :ok
  def handle_pool_event(_event_name, measurements, metadata, _config) do
    # Only log when pool is under stress
    if measurements[:queue] > 0 or measurements[:free] == 0 do
      Logger.warning("Connection pool stress",
        pool: metadata[:pool],
        in_use: measurements[:in_use],
        free: measurements[:free],
        queue: measurements[:queue]
      )
    end
  end

  @spec handle_parser_event(list(atom()), parser_measurements(), parser_metadata(), term()) :: :ok
  def handle_parser_event(_event_name, measurements, metadata, _config) do
    # Only log slow parsing operations (>1000ms)
    if measurements[:duration] > 1000 do
      Logger.warning("Slow parser operation",
        parser: metadata[:parser],
        duration_ms: measurements[:duration],
        size_bytes: measurements[:size],
        event_count: measurements[:event_count]
      )
    end
  end
end
