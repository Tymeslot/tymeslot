defmodule Tymeslot.Integrations.Calendar.Connection do
  @moduledoc """
  Business logic for connection validation with timeout semantics and provider checks.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Calendar.Shared.DiscoveryService
  alias Tymeslot.Integrations.Calendar.Tokens

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

  def validate_connection(%{provider: provider} = integration, _user_id)
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

    case DiscoveryService.discover_calendars(provider_atom, client_config) do
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

  `:scope` says who is asking: `:interactive` (the default, a user pressing
  "Test connection") or `:background` (a scheduled health probe). It decides the
  rate-limit bucket the provider charges the test to, and keeping the two apart
  is the point: an instance's scheduled probing must never be able to exhaust
  the budget a real user's button draws from, nor one user another's.
  """
  @type scope :: :interactive | :background

  @spec test_connection(CalendarIntegrationSchema.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def test_connection(%{provider: provider} = integration, opts \\ []) do
    with {:ok, provider_atom} <- ProviderConfig.parse_known(provider),
         {:ok, provider_module} <- ProviderRegistry.get_provider(provider_atom) do
      scope = rate_limit_scope(integration, Keyword.get(opts, :scope, :interactive))

      run_connection_test(provider_module, integration, rate_limit_scope: scope)
    else
      _other -> {:error, :unsupported_provider}
    end
  end

  defp rate_limit_scope(integration, :interactive),
    do: actor_scope({:user, Map.get(integration, :user_id)}, integration)

  defp rate_limit_scope(integration, :background),
    do: actor_scope({:integration, Map.get(integration, :id)}, integration)

  # Unsaved or partially built integrations (the connection-validation path
  # tests credentials before anything is persisted) carry no actor id yet, so
  # fall back to the target host rather than to one shared bucket.
  defp actor_scope({_kind, nil}, integration),
    do: {:host, URI.parse(Map.get(integration, :base_url) || "").host}

  defp actor_scope(scope, _integration), do: scope

  # Only the CalDAV-family providers rate-limit their connection test and so
  # accept caller context; the OAuth ones (Google, Outlook) expose arity 1 only.
  defp run_connection_test(provider_module, integration, opts) do
    if Code.ensure_loaded?(provider_module) and
         function_exported?(provider_module, :test_connection, 2) do
      provider_module.test_connection(integration, opts)
    else
      provider_module.test_connection(integration)
    end
  end
end
