defmodule Tymeslot.Integrations.Calendar.Connection do
  @moduledoc """
  Business logic for connection validation with timeout semantics and provider checks.
  """

  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Calendar.Shared.DiscoveryService
  alias Tymeslot.Integrations.Calendar.Tokens

  @type user_id :: pos_integer()

  @doc """
  Validate an integration's connection with a timeout.
  """
  @spec validate(map(), user_id(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(integration, user_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    task = Task.async(fn -> validate_connection(integration, user_id) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  @spec validate_connection(map(), user_id()) :: {:ok, map()} | {:error, term()}
  def validate_connection(%{provider: provider} = integration, user_id)
      when provider in ["google", "outlook"] do
    with {:ok, updated} <- Tokens.ensure_valid_token(integration, user_id),
         {:ok, _} <- test_connection(updated) do
      {:ok, updated}
    else
      {:error, :token_refresh_failed} -> {:error, :token_expired}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_connection(%{provider: provider} = integration, _user_id)
      when provider in ["caldav", "nextcloud", "radicale"] do
    client_config = %{
      base_url: integration.base_url,
      username: integration.username,
      password: integration.password
    }

    provider_atom =
      case ProviderRegistry.validate_provider(provider) do
        {:ok, atom} -> atom
        _ -> :unknown
      end

    case DiscoveryService.discover_calendars(provider_atom, client_config) do
      {:ok, _} -> {:ok, integration}
      {:error, _msg} -> {:error, :network_error}
    end
  rescue
    _ -> {:error, :network_error}
  end

  def validate_connection(_integration, _user_id), do: {:error, :unsupported_provider}

  @doc """
  Test provider connectivity via registry.
  """
  @spec test_connection(map()) :: {:ok, String.t()} | {:error, term()}
  def test_connection(%{provider: provider} = integration) do
    provider_atom =
      try do
        String.to_existing_atom(provider)
      rescue
        ArgumentError -> nil
      end

    case provider_atom && ProviderRegistry.get_provider(provider_atom) do
      {:ok, provider_module} -> provider_module.test_connection(integration)
      _ -> {:error, :unsupported_provider}
    end
  end
end
