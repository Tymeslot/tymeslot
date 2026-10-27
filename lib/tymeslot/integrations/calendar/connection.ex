defmodule Tymeslot.Integrations.Calendar.Connection do
  @moduledoc """
  Business logic for connection validation and provider checks.
  """

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Exchange.ClientConfig, as: ExchangeClientConfig
  alias Tymeslot.Integrations.Calendar.Provider
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Calendar.Shared.ErrorHandler
  alias Tymeslot.Integrations.Shared.ConnectionProbe

  @doc """
  Test provider connectivity via registry.

  This is the single place that resolves the provider module and hands off
  to `ConnectionProbe.probe/1`, which decides whether a connection test is
  rate-limited and, if so, who it is charged to — providers are pure I/O and
  never call the rate limiter themselves, and neither does this function.
  `:scope` says who is asking: `:interactive` (the default, a user pressing
  "Test connection") or `:background` (a scheduled health probe). Keeping
  the two apart is the point: an instance's scheduled probing must never be
  able to exhaust the budget a real user's button draws from, nor one user
  another's — and `:background` is unmetered by construction, per
  `ConnectionProbe`'s moduledoc.

  It also decides what a failure comes back as. Providers state a reason
  (`:unauthorized`, `:not_found`, …); an `:interactive` test is read by a
  person, so the reason is turned into copy here, while a `:background` probe
  is classified rather than read and gets the reason untouched. Flattening it
  early is what the health check cannot recover from: its classifier
  (`HealthCheck.ErrorAnalysis.classify_error/1`) recognises `:unauthorized` as
  a permanent credential failure, but a sentence saying the same thing falls
  through to its conservative `:transient` default, and a run of transient
  probes never advances `consecutive_hard_failures`.
  """
  @type scope :: ConnectionProbe.scope()

  @spec test_connection(CalendarIntegrationSchema.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def test_connection(%{provider: provider} = integration, opts \\ []) do
    scope = Keyword.get(opts, :scope, :interactive)
    start_time = System.monotonic_time(:millisecond)

    result =
      with {:ok, provider_atom} <- ProviderConfig.parse_known(provider),
           {:ok, provider_module} <- ProviderRegistry.get_provider(provider_atom) do
        config = provider_atom |> to_probe_config(integration) |> past_breaker(scope)

        provider_module
        |> ConnectionProbe.probe_provider(integration,
          scope: scope,
          # Deliberately nothing to validate here — see this function's doc.
          validate: fn -> :ok end,
          run: fn -> provider_module.perform_connection_test(config) end
        )
        |> tap(&reset_host_breaker_on_success(&1, provider_atom, integration))
        |> present_failure(scope, provider_atom)
      else
        _other -> {:error, :unsupported_provider}
      end

    :telemetry.execute(
      [:tymeslot, :integration, :test_connection],
      %{duration: System.monotonic_time(:millisecond) - start_time},
      %{provider: provider, type: "calendar", success: match?({:ok, _result}, result)}
    )

    result
  end

  # A self-hosted server's calls run through a breaker keyed by its host. Once
  # it has opened, an integration whose syncs are paused sends that server no
  # traffic, so nothing closes it again until it times out, and a fixed
  # server stays refused after "test connection succeeded". A test that
  # reached the server is the evidence it is back, so the host's breaker is
  # closed. A server shared by many accounts is left alone; see
  # `reset_host_breaker/1`.
  defp reset_host_breaker_on_success({:ok, _message}, _provider_atom, integration),
    do: reset_host_breaker(integration)

  defp reset_host_breaker_on_success(_failure, _provider_atom, _integration), do: :ok

  @doc """
  Closes the circuit breaker of `integration`'s self-hosted server, for a
  caller that has just reached that server successfully (a connection test,
  a reconnect's discovery).

  A no-op for a server shared by many accounts: Google and Outlook, whose
  breaker covers every account, and the CalDAV services at a fixed address
  (iCloud, mailbox.org), whose host breaker does. One account reaching such a
  server says nothing about the failures the others saw.
  """
  @spec reset_host_breaker(map()) :: :ok
  def reset_host_breaker(%{provider: provider} = integration) do
    with {:ok, provider_atom} <- ProviderConfig.parse_known(provider),
         nil <- ProviderConfig.locked_url_for(provider_atom),
         {breaker_provider, host} when is_binary(host) <-
           CalendarCircuitBreaker.breaker_key(provider_atom, Map.get(integration, :base_url)) do
      CalendarCircuitBreaker.reset(breaker_provider, host)
    end

    :ok
  end

  # CalDAV-family `validate_config/1` and `perform_connection_test/1` callbacks read
  # `config` with bracket access, which the persisted `CalendarIntegrationSchema`
  # struct doesn't support. Converts it to the same atom-keyed map
  # `Calendar.Creation.prevalidate_config/1` builds from form attrs, so
  # `probe/3` always receives one shape per provider family. A caller that
  # already passes a plain map is left untouched; OAuth providers read the
  # struct directly (dot/`Map` access) and are never converted.
  defp to_probe_config(provider_atom, %CalendarIntegrationSchema{} = integration) do
    cond do
      ProviderConfig.caldav_based?(provider_atom) ->
        CalendarIntegrationSchema.to_provider_config(integration)

      ProviderConfig.ews?(provider_atom) ->
        ExchangeClientConfig.new(integration)

      true ->
        integration
    end
  end

  defp to_probe_config(_provider_atom, config), do: config

  # A person pressing "Test connection" is asking whether the server is back,
  # which a test refused by the host breaker an earlier outage opened cannot
  # answer; the press is rate-limited, so it is let past. A CalDAV test needs
  # no flag: its probe never runs through the breaker.
  # A `:background` probe stays behind the breaker like any other traffic.
  defp past_breaker(%ExchangeClientConfig{} = config, :interactive),
    do: %{config | skip_breaker: true}

  defp past_breaker(config, _scope), do: config

  # Copy for the reader of an `:interactive` test, per `test_connection/2`.
  # Everything else is passed through: a `:background` probe wants the reason
  # as it stands, a `ConnectionProbe` refusal keeps its tag so the web layer
  # can write its own copy for it, and a message a provider already phrased is
  # left alone — `sanitize_error_message/2` matches English keywords, so
  # re-reading a localised sentence would re-classify it by its wording.
  defp present_failure({:error, reason}, :interactive, provider_atom),
    do: {:error, display_reason(reason, provider_atom)}

  defp present_failure(result, _scope, _provider_atom), do: result

  defp display_reason({:rate_limited, _message} = refusal, _provider_atom), do: refusal
  defp display_reason(:unattributable, _provider_atom), do: :unattributable
  defp display_reason(reason, _provider_atom) when is_binary(reason), do: reason

  defp display_reason(reason, provider_atom),
    do: ErrorHandler.sanitize_error_message(reason, provider_atom)

  @doc """
  Runs the rate-limited connection probe for `provider_atom` against `config`,
  charging an already-resolved `actor`.

  Resolves the provider module from `provider_atom` and asks it for its own
  connection-test bucket via `connection_test_bucket/0` (each provider's
  behaviour declares this callback with no default, so a provider can't omit
  it). `actor` must already be a resolved `ConnectionProbe.actor()` for any
  provider with a real bucket; `:unmetered` providers ignore it and callers
  may pass `nil`. Unlike `test_connection/2`, there is no persisted
  integration to resolve an actor from here — the caller already knows who
  is submitting the form.

  Deliberately does NOT call `validate_config/1`. That callback validates
  user-supplied *input*, not persisted state: it requires a complete config
  and, for OAuth providers, checks the stored `oauth_scope` against a
  provider-specific format. This function's one call path is the creation
  pre-check, where the config really is untrusted input and structural
  validation runs ahead of it (`Calendar.Creation.prevalidate_config/1`).

  Returns `ConnectionProbe`'s refusal tagged, never flattened to text —
  building copy for it is the caller's job (see the moduledoc on
  `Tymeslot.Integrations.Shared.ConnectionProbe`); `Calendar.Creation`
  passes it straight up to its own caller.

  `Calendar.Creation.prevalidate_config/1` (via its private `test_config/3`)
  is the only caller.
  """
  @spec probe(atom(), Provider.config(), ConnectionProbe.actor() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def probe(provider_atom, config, actor) do
    case ProviderRegistry.get_provider(provider_atom) do
      {:ok, provider_module} ->
        ConnectionProbe.probe(%ConnectionProbe.Request{
          provider_module: provider_module,
          scope: :interactive,
          actor: actor,
          # Every caller here is a creation pre-check, not the "Test connection"
          # button, and a refusal has to say so: the organiser pressed "Add".
          action: :calendar_setup,
          # Deliberately nothing to validate here — see this function's doc.
          validate: fn -> :ok end,
          run: fn -> provider_module.perform_connection_test(config) end
        })

      _other ->
        {:error, :unsupported_provider}
    end
  end
end
