defmodule Tymeslot.Infrastructure.ProviderBreakers do
  @moduledoc """
  The circuit breakers guarding calendar and video provider calls, one module
  for both kinds.

  Each kind has a breaker per provider, started by `CircuitBreakerSupervisor`
  from `child_specs/1`, and a breaker per server host, started on first use
  under `DynamicCircuitBreakerSupervisor`. Self-hosted providers (the CalDAV
  family, Exchange, MiroTalk) pass the host of their `base_url` so that one
  tenant's outage cannot trip calls to another tenant's server; OAuth
  providers share the provider-level breaker.

  Every reader of a host breaker (`status/3`, `reset/3`) derives the host with
  `host_from_base_url/1`, and `name/3` downcases it, so the breaker a call trips
  and the one a health check reads or a reconnect resets are the same process.
  Host breakers are keyed by the tuple `{kind, provider, host}` in
  `CircuitBreakerRegistry`, so two hosts differing only in punctuation never
  share one.

  `CalendarCircuitBreaker` and `VideoCircuitBreaker` remain as the per-kind
  entry points their callers already use.
  """

  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviderConfig
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig
  require Logger

  @registry Tymeslot.Infrastructure.CircuitBreakerRegistry
  @dynamic_supervisor Tymeslot.Infrastructure.DynamicCircuitBreakerSupervisor

  @type kind :: :calendar | :video

  @typedoc """
  What a wrapped call resolves to.

  The same shape as `t:Tymeslot.Infrastructure.CircuitBreaker.result/0` minus
  `{:provider_error, reason}`, which is translated to `{:error, reason}`.
  """
  @type result :: :ok | {:ok, any()} | {:error, any()} | {:error, any(), any()}

  @default_config %{
    failure_threshold: 3,
    time_window: :timer.minutes(1),
    recovery_timeout: :timer.minutes(2),
    half_open_requests: 2
  }

  # OAuth providers are more lenient (rate limits and API quotas produce
  # bursts of failures that are not outages); Nextcloud slightly so, for its
  # heavier server operations. Every other provider takes the defaults.
  @lenient %{failure_threshold: 5, recovery_timeout: :timer.minutes(5)}

  @kinds %{
    calendar: %{
      label: "Calendar",
      providers: CalendarProviderConfig.providers_with_circuit_breakers(),
      configs: %{
        google: @lenient,
        outlook: @lenient,
        nextcloud: %{failure_threshold: 4, recovery_timeout: :timer.minutes(3)}
      }
    },
    video: %{
      label: "Video",
      # Every known provider, switched off or not: a provider switched off
      # still serves the integrations connected before the switch.
      providers:
        Enum.filter(
          VideoProviderConfig.known_providers(),
          &VideoProviderConfig.circuit_breaker_enabled?/1
        ),
      configs: %{google_meet: @lenient, teams: @lenient}
    }
  }

  # The provider breakers' registered names, built once from a bounded,
  # compile-time provider list.
  @static_names (for {kind, %{providers: providers}} <- @kinds,
                     provider <- providers,
                     into: %{} do
                   # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
                   {{kind, provider}, :"#{kind}_breaker_#{provider}"}
                 end)

  defguardp is_host(host) when is_binary(host) and host != ""

  @doc "The providers of `kind` that have a provider-level breaker."
  @spec providers(kind()) :: [atom()]
  def providers(kind), do: @kinds |> Map.fetch!(kind) |> Map.fetch!(:providers)

  @doc "The breaker configuration for `provider` of `kind`."
  @spec config(kind(), atom()) :: map()
  def config(kind, provider) do
    Map.merge(
      @default_config,
      @kinds |> Map.fetch!(kind) |> Map.fetch!(:configs) |> Map.get(provider, %{})
    )
  end

  @doc "Child specs for the provider-level breakers of `kind`."
  @spec child_specs(kind()) :: [Supervisor.child_spec()]
  def child_specs(kind) do
    for provider <- providers(kind) do
      name = Map.fetch!(@static_names, {kind, provider})

      Supervisor.child_spec({CircuitBreaker, name: name, config: config(kind, provider)},
        id: name
      )
    end
  end

  @doc """
  The registered name of `provider`'s breaker, or of its breaker for `host`.

  Returns `nil` for a provider-level name of a provider that has none.
  """
  @spec name(kind(), atom(), String.t() | nil) :: GenServer.name() | nil
  def name(kind, provider, host \\ nil)

  def name(kind, provider, host) when is_atom(provider) and is_host(host),
    do: {:via, Registry, {@registry, {kind, provider, String.downcase(host)}}}

  def name(kind, provider, _host), do: Map.get(@static_names, {kind, provider})

  @doc """
  The host of a self-hosted provider's `base_url`, for keying its breaker.

  Returns `nil` when `base_url` is absent or has no host; the caller then
  falls back to the provider-level breaker, as OAuth providers do.
  """
  @spec host_from_base_url(String.t() | nil) :: String.t() | nil
  def host_from_base_url(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: host} when is_host(host) -> host
      _other -> nil
    end
  end

  def host_from_base_url(_base_url), do: nil

  @doc """
  Runs `fun` through `provider`'s breaker: its host breaker when `opts` carry
  a `:host`, started on first use, and the provider-level breaker otherwise.
  `skip_breaker: true` runs `fun` unguarded.
  """
  @spec with_breaker(kind(), atom(), keyword(), (-> any())) :: any()
  def with_breaker(kind, provider, opts, fun) when is_function(fun, 0) do
    host = Keyword.get(opts, :host)

    cond do
      Keyword.get(opts, :skip_breaker, false) -> fun.()
      is_host(host) -> call_with_host(kind, provider, host, fun)
      true -> call(kind, provider, fun)
    end
  end

  @doc "Runs `fun` through `provider`'s provider-level breaker."
  @spec call(kind(), atom(), (-> any())) :: result()
  def call(kind, provider, fun) when is_function(fun, 0) do
    case name(kind, provider) do
      nil -> {:error, {:invalid_provider, provider}}
      name -> run(name, kind, [provider: provider], fun)
    end
  end

  @doc "Runs `fun` through `provider`'s breaker for `host`, starting it if needed."
  @spec call_with_host(kind(), atom(), String.t(), (-> any())) :: result()
  def call_with_host(kind, provider, host, fun)
      when is_atom(provider) and is_host(host) and is_function(fun, 0) do
    name = name(kind, provider, host)
    ensure_started(name, config(kind, provider))
    run(name, kind, [provider: provider, host: host], fun)
  end

  @doc """
  The status map of `provider`'s breaker, or of its breaker for `host`
  (derive it with `host_from_base_url/1`).

  `{:error, :breaker_not_found}` when the breaker is not running, which for a
  host breaker means no call has gone through it since it last idled out.
  """
  @spec status(kind(), atom(), String.t() | nil) :: map() | {:error, term()}
  def status(kind, provider, host \\ nil) do
    with {:ok, name} <- existing(kind, provider, host), do: CircuitBreaker.status(name)
  end

  @doc "Closes `provider`'s breaker, or its breaker for `host` (see `status/3`)."
  @spec reset(kind(), atom(), String.t() | nil) :: :ok | {:error, term()}
  def reset(kind, provider, host \\ nil) do
    with {:ok, name} <- existing(kind, provider, host) do
      CircuitBreaker.reset(name)
      Logger.info("Circuit breaker reset", service: label(kind), provider: provider, host: host)
      :ok
    end
  end

  @doc """
  Closes every host breaker of either kind.

  Host breakers are started per host and otherwise keep their failure counts;
  used by tests, where breaker state must not leak between cases.
  """
  @spec reset_all_hosts() :: :ok
  def reset_all_hosts do
    for {_id, pid, :worker, _modules} when is_pid(pid) <-
          DynamicSupervisor.which_children(@dynamic_supervisor),
        key <- Registry.keys(@registry, pid) do
      # By name, not pid: the persisted snapshot is keyed by the name.
      CircuitBreaker.reset({:via, Registry, {@registry, key}})
    end

    :ok
  end

  @doc "Whether the breaker registered as `name` is running."
  @spec breaker_exists?(GenServer.name()) :: boolean()
  def breaker_exists?({:via, Registry, {registry, key}}), do: Registry.lookup(registry, key) != []
  def breaker_exists?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp existing(kind, provider, host) do
    case name(kind, provider, host) do
      nil -> {:error, {:invalid_provider, provider}}
      name -> if breaker_exists?(name), do: {:ok, name}, else: {:error, :breaker_not_found}
    end
  end

  defp ensure_started(name, config) do
    unless breaker_exists?(name) do
      DynamicSupervisor.start_child(
        @dynamic_supervisor,
        {CircuitBreaker,
         name: name, config: config, idle_timeout: CircuitBreaker.default_idle_timeout()}
      )
    end
  end

  defp run(name, kind, context, fun) do
    if breaker_exists?(name) do
      name |> CircuitBreaker.call(fun) |> log_and_map(kind, context)
    else
      Logger.error("Circuit breaker not found - it should be started by supervisor",
        provider: context[:provider],
        breaker_name: LogFormat.reason(name)
      )

      {:error, :breaker_not_found}
    end
  rescue
    error -> breaker_error(error, kind, context)
  catch
    # `breaker_exists?/1` and `CircuitBreaker.call/3` are two separate
    # messages, so the breaker can stop (idle timeout, crash) in between;
    # `GenServer.call/3` then exits with `:noproc`, which `rescue` cannot see.
    :exit, reason -> breaker_error(reason, kind, context)
  end

  defp log_and_map(:ok, _kind, _context), do: :ok
  defp log_and_map({:ok, _result} = ok, _kind, _context), do: ok

  defp log_and_map({:error, :circuit_open} = error, kind, context) do
    Logger.warning(prefixed(context, "Circuit breaker open"), [service: label(kind)] ++ context)
    error
  end

  defp log_and_map({:provider_error, reason}, kind, context) do
    log_failure(reason, kind, context)
    {:error, reason}
  end

  defp log_and_map({:error, _reason, _message} = error, kind, context) do
    log_failure(error, kind, context)
    error
  end

  defp log_and_map({:error, reason} = error, kind, context) do
    log_failure(reason, kind, context)
    error
  end

  defp log_failure(reason, kind, context) do
    Logger.error(
      prefixed(context, "Operation failed"),
      [service: label(kind), error: LogFormat.reason(reason)] ++ context
    )
  end

  defp breaker_error(reason, kind, context) do
    Logger.error(
      prefixed(context, "Circuit breaker error"),
      [service: label(kind), error: LogFormat.reason(reason)] ++ context
    )

    {:error, :circuit_breaker_error}
  end

  # "Circuit breaker open" becomes "Host circuit breaker open" for a host breaker.
  defp prefixed(context, <<first::utf8, rest::binary>> = message) do
    if Keyword.has_key?(context, :host),
      do: "Host " <> String.downcase(<<first::utf8>>) <> rest,
      else: message
  end

  defp label(kind), do: @kinds |> Map.fetch!(kind) |> Map.fetch!(:label)
end
