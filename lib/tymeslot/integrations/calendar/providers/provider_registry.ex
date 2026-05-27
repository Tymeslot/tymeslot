defmodule Tymeslot.Integrations.Calendar.Providers.ProviderRegistry do
  @moduledoc """
  Registry for calendar providers.

  This module manages the available calendar providers and provides
  a way to get the appropriate provider implementation.
  Uses the centralized ProviderConfig for provider definitions.
  """

  alias Tymeslot.Integrations.Calendar.ProviderConfig

  use Tymeslot.Integrations.Common.ProviderRegistry,
    provider_type_name: "provider",
    default_provider: :caldav,
    metadata_fields: [],
    providers: %{
      caldav: Tymeslot.Integrations.Calendar.CalDAV.Provider,
      radicale: Tymeslot.Integrations.Calendar.Radicale.Provider,
      nextcloud: Tymeslot.Integrations.Calendar.Nextcloud.Provider,
      zimbra: Tymeslot.Integrations.Calendar.Zimbra.Provider,
      mailbox_org: Tymeslot.Integrations.Calendar.MailboxOrg.Provider,
      baikal: Tymeslot.Integrations.Calendar.Baikal.Provider,
      google: Tymeslot.Integrations.Calendar.Google.Provider,
      outlook: Tymeslot.Integrations.Calendar.Outlook.Provider,
      debug: Tymeslot.Integrations.Calendar.DebugCalendarProvider,
      demo: Tymeslot.Integrations.Calendar.DemoCalendarProvider
    }

  @doc """
  Validates if a provider type is supported.
  Delegates to ProviderConfig for consistency.

  ## Examples

      iex> ProviderRegistry.valid_provider?(:google)
      true
      
      iex> ProviderRegistry.valid_provider?(:invalid)
      false
  """
  @spec valid_provider?(atom()) :: boolean()
  defdelegate valid_provider?(provider), to: ProviderConfig

  # Toggle-agnostic module lookup: returns the provider module for any known
  # provider, regardless of whether it is currently enabled via config. This
  # ensures persisted integrations (sync, room creation, connection test)
  # continue to function when a provider has been disabled after the
  # integration was created. Enforcement of the toggle belongs at user-input
  # boundaries (form validation, new-connection flows), not here.
  @spec get_provider(atom() | String.t()) :: {:ok, module()} | {:error, String.t()}
  def get_provider(provider_type) do
    with {:ok, type} <- ProviderConfig.parse_known(provider_type),
         module when is_atom(module) and module != nil <-
           ProviderConfig.get_provider_module(type) do
      {:ok, module}
    else
      _other -> {:error, "Unknown provider type: #{inspect(provider_type)}"}
    end
  end

  @doc """
  Returns a list of all valid provider types.
  Delegates to `ProviderConfig.all_providers_with_dev/0`, so the result reflects
  whichever providers are enabled at runtime.
  """
  @spec valid_providers() :: list(atom())
  defdelegate valid_providers(), to: ProviderConfig, as: :all_providers_with_dev

  @doc """
  Validates and normalizes a provider type.
  Delegates to ProviderConfig for consistency.

  Returns {:ok, provider} if valid, {:error, reason} otherwise.

  ## Examples

      iex> ProviderRegistry.validate_provider(:google)
      {:ok, :google}

      iex> ProviderRegistry.validate_provider("google")
      {:ok, :google}

      iex> match?({:error, _}, ProviderRegistry.validate_provider(:invalid))
      true
  """
  @spec validate_provider(atom() | String.t()) :: {:ok, atom()} | {:error, String.t()}
  defdelegate validate_provider(provider), to: ProviderConfig

  @doc """
  Creates a new client for the specified provider.

  This is a calendar-specific function that validates and creates provider instances.

  ## Options
  - `skip_validation`: Skip config validation for operational client creation (default: false)
  """
  @spec create_client(atom(), map(), keyword()) :: {:ok, any()} | {:error, any()}
  def create_client(provider_type, config, opts \\ []) do
    skip_validation = Keyword.get(opts, :skip_validation, false)

    case get_provider(provider_type) do
      {:ok, module} ->
        if skip_validation do
          # Direct creation for operational use - skip validation to avoid rate limiting
          create_client_without_validation(module, config)
        else
          # Full validation for setup/configuration
          create_client_with_validation(module, config)
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Helper for creating client with full validation (setup/configuration)
  defp create_client_with_validation(module, config) do
    case module.validate_config(config) do
      :ok ->
        case module.new(config) do
          {:ok, client} -> {:ok, client}
          # Handle providers that return the client directly
          client -> {:ok, client}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Helper for creating client without validation (operational use)
  defp create_client_without_validation(module, config) do
    case module.new(config) do
      {:ok, client} -> {:ok, client}
      # Handle providers that return the client directly
      client -> {:ok, client}
    end
  end
end
