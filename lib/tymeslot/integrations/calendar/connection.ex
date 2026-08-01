defmodule Tymeslot.Integrations.Calendar.Connection do
  @moduledoc """
  Business logic for connection validation with timeout semantics and provider checks.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.Provider
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.Shared.ConnectionProbe

  require Logger

  require Logger

  @type user_id :: pos_integer()

  @caldav_provider_strings ProviderConfig.caldav_based_provider_strings()

  @doc """
  Validate an integration's connection with a timeout.
  """
  @spec validate(CalendarIntegrationSchema.t(), user_id(), keyword()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, term()}
  def validate(integration, user_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    task =
      Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
        validate_connection(integration, user_id)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  @spec validate_connection(CalendarIntegrationSchema.t(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, term()}
  def validate_connection(%{provider: provider} = integration, user_id)
      when provider in ["google", "outlook"] do
    with {:ok, updated} <- Tokens.ensure_valid_token(integration, user_id),
         {:ok, _result} <- test_connection(updated) do
      {:ok, updated}
    else
      {:error, reason} when reason in [:token_refresh_failed, :token_persistence_failed] ->
        {:error, :token_expired}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def validate_connection(%{provider: provider} = integration, user_id)
      when provider in @caldav_provider_strings do
    client_config = %{
      base_url: integration.base_url,
      username: integration.username,
      password: integration.password
    }

    provider_atom =
      case ProviderConfig.parse_known(provider) do
        {:ok, atom} -> atom
        _other -> :unknown
      end

    # Reaches `Discovery` directly rather than through `probe/3` — metering
    # happens at the `Discovery` funnel itself, charged to the acting user,
    # so no second charge is needed here.
    case Discovery.discover_calendars(provider_atom, client_config, actor: {:user, user_id}) do
      {:ok, _result} -> {:ok, integration}
      {:error, _msg} -> {:error, :network_error}
    end
  rescue
    error ->
      # `client_config` carries the CalDAV password; never include it here.
      Logger.warning("CalDAV calendar discovery raised during connection validation",
        provider: provider,
        integration_id: integration.id,
        error: inspect(error)
      )

      {:error, :network_error}
  end

  def validate_connection(_integration, _user_id), do: {:error, :unsupported_provider}

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
        config = to_probe_config(provider_atom, integration)

        ConnectionProbe.probe_provider(provider_module, integration,
          scope: scope,
          # Deliberately nothing to validate here — see this function's doc.
          validate: fn -> :ok end,
          run: fn -> provider_module.perform_connection_test(config) end
        )
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

  # CalDAV-family `validate_config/1` and `perform_connection_test/1` callbacks read
  # `config` with bracket access, which the persisted `CalendarIntegrationSchema`
  # struct doesn't support. Converts it to the same atom-keyed map
  # `Calendar.Creation.prevalidate_config/1` builds from form attrs, so
  # `probe/3` always receives one shape per provider family. A caller that
  # already passes a plain map is left untouched; OAuth providers read the
  # struct directly (dot/`Map` access) and are never converted.
  defp to_probe_config(provider_atom, %CalendarIntegrationSchema{} = integration) do
    if ProviderConfig.caldav_based?(provider_atom) do
      CalendarIntegrationSchema.to_provider_config(integration)
    else
      integration
    end
  end

  defp to_probe_config(_provider_atom, config), do: config

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
          # Deliberately nothing to validate here — see this function's doc.
          validate: fn -> :ok end,
          run: fn -> provider_module.perform_connection_test(config) end
        })

      _other ->
        {:error, :unsupported_provider}
    end
  end
end
