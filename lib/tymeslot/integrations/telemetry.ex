defmodule Tymeslot.Integrations.Telemetry do
  @moduledoc """
  Telemetry instrumentation for integration operations.

  This module provides:
  - Telemetry event definitions for all integration operations
  - Structured logging with correlation IDs
  - Performance metrics collection
  - Error tracking and categorization
  """

  require Logger

  alias Telemetry.Metrics

  @doc """
  List of all telemetry events emitted by the integrations system.
  """
  @spec events() :: [[atom()]]
  def events do
    [
      # Integration operations
      [:tymeslot, :integration, :operation, :start],
      [:tymeslot, :integration, :operation, :stop],
      [:tymeslot, :integration, :operation, :exception],

      # API calls
      [:tymeslot, :integration, :api_call, :start],
      [:tymeslot, :integration, :api_call, :stop],
      [:tymeslot, :integration, :api_call, :exception],

      # OAuth operations
      [:tymeslot, :integration, :oauth, :token_refresh],
      [:tymeslot, :integration, :oauth, :authorization],

      # Health checks
      [:tymeslot, :integration, :health_check],
      [:tymeslot, :integration, :circuit_breaker, :state_change],

      # Cache operations
      [:tymeslot, :cache, :hit],
      [:tymeslot, :cache, :miss],
      [:tymeslot, :cache, :put],
      [:tymeslot, :cache, :eviction],

      # Data sync
      [:tymeslot, :integration, :sync, :start],
      [:tymeslot, :integration, :sync, :complete],
      [:tymeslot, :integration, :sync, :conflict]
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
  Executes a function with telemetry instrumentation.
  """
  @spec span(list(atom()), map(), (-> term())) :: term()
  def span(event_prefix, metadata, fun) when is_function(fun, 0) do
    start_time = System.monotonic_time()
    start_metadata = Map.merge(metadata, %{correlation_id: generate_correlation_id()})

    :telemetry.execute(
      event_prefix ++ [:start],
      %{system_time: System.system_time()},
      start_metadata
    )

    try do
      result = fun.()

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        event_prefix ++ [:stop],
        %{duration: duration},
        Map.put(start_metadata, :result, :ok)
      )

      result
    rescue
      exception ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(start_metadata, %{
            kind: :error,
            reason: Exception.message(exception),
            stacktrace: __STACKTRACE__
          })
        )

        reraise exception, __STACKTRACE__
    end
  end

  @doc """
  Records an API call with detailed metrics.
  """
  @spec record_api_call(atom(), atom(), map()) :: term()
  def record_api_call(provider, operation, metadata \\ %{}) do
    span(
      [:tymeslot, :integration, :api_call],
      Map.merge(metadata, %{provider: provider, operation: operation}),
      fn -> yield() end
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

  defp determine_log_level(event, metadata) do
    case event do
      [:tymeslot, :integration, :operation, :exception] ->
        :error

      [:tymeslot, :integration, :api_call, :exception] ->
        :error

      [:tymeslot, :integration, :health_check] when metadata.success == false ->
        :warning

      [:tymeslot, :integration, :circuit_breaker, :state_change]
      when metadata.to == :open ->
        :error

      [:tymeslot, :integration, :sync, :conflict] ->
        :warning

      _ ->
        :debug
    end
  end

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
         [:tymeslot, :integration, :operation, :start],
         _measurements,
         metadata,
         _event_name
       ) do
    "Integration operation started: #{metadata.operation}"
  end

  defp format_event_message(
         [:tymeslot, :integration, :operation, :stop],
         measurements,
         metadata,
         _event_name
       ) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    "Integration operation completed: #{metadata.operation} (#{duration_ms}ms)"
  end

  defp format_event_message(
         [:tymeslot, :integration, :operation, :exception],
         _measurements,
         metadata,
         _event_name
       ) do
    "Integration operation failed: #{metadata.operation} - #{metadata.reason}"
  end

  defp format_event_message(
         [:tymeslot, :integration, :api_call, :start],
         _measurements,
         metadata,
         _event_name
       ) do
    "API call started: #{metadata.provider} - #{metadata.operation}"
  end

  defp format_event_message(
         [:tymeslot, :integration, :api_call, :stop],
         measurements,
         metadata,
         _event_name
       ) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    "API call completed: #{metadata.provider} - #{metadata.operation} (#{duration_ms}ms)"
  end

  defp format_event_message(
         [:tymeslot, :integration, :api_call, :exception],
         _measurements,
         metadata,
         _event_name
       ) do
    "API call failed: #{metadata.provider} - #{metadata.operation} - #{metadata.reason}"
  end

  defp format_event_message(
         [:tymeslot, :integration, :oauth, :token_refresh],
         _measurements,
         metadata,
         _event_name
       ) do
    status = if metadata.success, do: "success", else: "failed"
    "OAuth token refresh: #{metadata.provider} - #{status}"
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

  defp format_event_message([:tymeslot, :cache, :hit], _measurements, metadata, _event_name) do
    "Cache hit: #{metadata.cache}"
  end

  defp format_event_message(
         [:tymeslot, :cache, :miss],
         _measurements,
         metadata,
         _event_name
       ) do
    "Cache miss: #{metadata.cache}"
  end

  defp format_event_message(
         [:tymeslot, :integration, :sync, :complete],
         measurements,
         metadata,
         _event_name
       ) do
    "Data sync completed: #{metadata.provider} - #{measurements.events_synced} events"
  end

  defp format_event_message(_event, _measurements, _metadata, event_name) do
    "Event: #{event_name}"
  end

  defp format_metadata(metadata) do
    Enum.into(
      Enum.filter(Map.drop(metadata, [:correlation_id, :operation, :provider]), fn {_k, v} ->
        v != nil
      end),
      %{}
    )
  end

  defp generate_correlation_id do
    Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp yield do
    receive do
      {:continue, result} -> result
    end
  end
end

defmodule Tymeslot.Integrations.Metrics do
  @moduledoc """
  Telemetry metrics definitions for monitoring integration performance.
  """

  alias Telemetry.Metrics

  @spec metrics() :: list(Metrics.t())
  def metrics do
    [
      # Operation metrics
      Metrics.counter(
        "tymeslot.integration.operation.count",
        tags: [:provider, :operation, :result]
      ),
      Metrics.summary(
        "tymeslot.integration.operation.duration",
        tags: [:provider, :operation],
        unit: {:native, :millisecond}
      ),

      # API call metrics
      Metrics.counter(
        "tymeslot.integration.api_call.count",
        tags: [:provider, :operation, :result]
      ),
      Metrics.summary(
        "tymeslot.integration.api_call.duration",
        tags: [:provider, :operation],
        unit: {:native, :millisecond}
      ),

      # Health check metrics
      Metrics.counter(
        "tymeslot.integration.health_check.count",
        tags: [:provider, :type, :success]
      ),
      Metrics.last_value(
        "tymeslot.integration.health_check.status",
        tags: [:provider, :type],
        measurement: fn _measurements, metadata ->
          if metadata.success, do: 1, else: 0
        end
      ),

      # Cache metrics
      Metrics.counter(
        "tymeslot.cache.operations",
        event_name: [:tymeslot, :cache, :hit],
        tags: [:cache]
      ),
      Metrics.counter(
        "tymeslot.cache.operations",
        event_name: [:tymeslot, :cache, :miss],
        tags: [:cache]
      ),

      # OAuth metrics
      Metrics.counter(
        "tymeslot.integration.oauth.token_refresh",
        tags: [:provider, :success]
      ),

      # Circuit breaker metrics
      Metrics.counter(
        "tymeslot.integration.circuit_breaker.state_changes",
        tags: [:provider, :from, :to]
      )
    ]
  end
end
