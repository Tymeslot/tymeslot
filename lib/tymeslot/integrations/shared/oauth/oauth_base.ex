defmodule Tymeslot.Integrations.Common.OAuthBase do
  @moduledoc """
  Common OAuth functionality for calendar providers.

  This module provides shared OAuth configuration, validation, and utility functions
  that are common across different OAuth-based calendar providers like Google and Outlook.
  """

  alias Tymeslot.Integrations.Common.ConfigManager

  # Type definitions
  @type oauth_config :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          token_expires_at: DateTime.t(),
          oauth_scope: String.t()
        }

  @type oauth_tokens :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: DateTime.t(),
          scope: String.t()
        }

  @doc """
  Provides the common OAuth configuration schema used by all OAuth providers.
  """
  @spec config_schema() :: map()
  def config_schema do
    ConfigManager.oauth_schema()
  end

  @doc """
  Validates OAuth configuration ensuring all required fields are present.

  Delegates to provider-specific OAuth scope validation if all required fields are present.
  """
  @spec validate_config(map(), (map() -> :ok | {:error, String.t()})) ::
          :ok | {:error, String.t()}
  def validate_config(config, scope_validator_fn) when is_function(scope_validator_fn, 1) do
    required_fields = [:access_token, :refresh_token, :token_expires_at, :oauth_scope]

    missing_fields =
      Enum.map(Enum.reject(required_fields, &Map.has_key?(config, &1)), &to_string/1)

    case missing_fields do
      [] -> scope_validator_fn.(config)
      fields -> {:error, "Missing required fields: #{Enum.join(fields, ", ")}"}
    end
  end

  @doc """
  Creates a new OAuth provider instance with validated configuration.
  """
  @spec new(map(), (map() -> :ok | {:error, String.t()})) ::
          {:ok, oauth_config()} | {:error, String.t()}
  def new(config, scope_validator_fn)
      when is_map(config) and is_function(scope_validator_fn, 1) do
    case validate_config(config, scope_validator_fn) do
      :ok -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the default start time for calendar queries (30 days ago).
  """
  @spec default_start_time() :: DateTime.t()
  def default_start_time do
    DateTime.utc_now()
    |> DateTime.add(-30, :day)
    |> DateTime.truncate(:second)
  end

  @doc """
  Returns the default end time for calendar queries (365 days from now).
  """
  @spec default_end_time() :: DateTime.t()
  def default_end_time do
    DateTime.utc_now()
    |> DateTime.add(365, :day)
    |> DateTime.truncate(:second)
  end

  @doc """
  Wraps API calls with standardized error handling.

  Converts provider-specific error tuples to normalized format.
  """
  @spec handle_api_call((-> any()), (any() -> any())) :: {:ok, any()} | {:error, any()} | :ok
  def handle_api_call(api_call_fn, conversion_fn \\ &Function.identity/1)
      when is_function(api_call_fn, 0) and is_function(conversion_fn, 1) do
    case api_call_fn.() do
      {:ok, result} -> {:ok, conversion_fn.(result)}
      :ok -> :ok
      {:error, _type, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates or updates a calendar integration in the database.

  This handles the common pattern of checking if an integration exists and either
  creating or updating it accordingly.
  """
  @spec create_or_update_integration(integer(), String.t(), map(), oauth_tokens()) ::
          {:ok, any()} | {:error, any()}
  def create_or_update_integration(user_id, provider_name, provider_config, tokens) do
    alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries

    case CalendarIntegrationQueries.get_by_user_and_provider(user_id, provider_name) do
      {:error, :not_found} ->
        attrs =
          Map.merge(provider_config, %{
            user_id: user_id,
            provider: provider_name,
            access_token: tokens.access_token,
            refresh_token: tokens.refresh_token,
            token_expires_at: tokens.expires_at,
            oauth_scope: tokens.scope,
            is_active: true
          })

        CalendarIntegrationQueries.create_with_auto_primary(attrs)

      {:ok, existing_integration} ->
        attrs = %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          token_expires_at: tokens.expires_at,
          oauth_scope: tokens.scope,
          is_active: true
        }

        CalendarIntegrationQueries.update(existing_integration, attrs)
    end
  end

  @doc """
  Macro for creating OAuth-based calendar providers.

  This macro injects common OAuth functionality while allowing providers
  to customize their specific behavior through callbacks.
  """
  defmacro __using__(opts) do
    provider_name = Keyword.fetch!(opts, :provider_name)
    display_name = Keyword.fetch!(opts, :display_name)
    base_url = Keyword.fetch!(opts, :base_url)

    quote do
      @behaviour Tymeslot.Integrations.Calendar.Providers.ProviderBehaviour

      alias Tymeslot.Integrations.Common.OAuthBase

      @provider_name unquote(provider_name)
      @display_name unquote(display_name)
      @base_url unquote(base_url)

      @impl true
      def provider_type, do: String.to_existing_atom(@provider_name)

      @impl true
      def display_name, do: @display_name

      @impl true
      def config_schema, do: OAuthBase.config_schema()

      @impl true
      def new(config) do
        OAuthBase.new(config, &validate_oauth_scope/1)
      end

      @impl true
      def validate_config(config) do
        OAuthBase.validate_config(config, &validate_oauth_scope/1)
      end

      @impl true
      def get_events(integration) do
        get_events(integration, nil, nil)
      end

      @impl true
      def get_events(integration, start_time, end_time) do
        start_time = start_time || default_start_time()
        end_time = end_time || default_end_time()

        OAuthBase.handle_api_call(
          fn -> call_list_events(integration, start_time, end_time) end,
          &convert_events/1
        )
      end

      @impl true
      def create_event(integration, event_attrs) do
        OAuthBase.handle_api_call(
          fn -> call_create_event(integration, event_attrs) end,
          &convert_event/1
        )
      end

      @impl true
      def update_event(integration, event_id, event_attrs) do
        OAuthBase.handle_api_call(
          fn -> call_update_event(integration, event_id, event_attrs) end,
          &convert_event/1
        )
      end

      @impl true
      def delete_event(integration, event_id) do
        OAuthBase.handle_api_call(fn -> call_delete_event(integration, event_id) end)
      end

      # Provider-specific callbacks that must be implemented
      @callback validate_oauth_scope(config :: map()) :: :ok | {:error, String.t()}
      @callback convert_events(events :: list()) :: list()
      @callback convert_event(event :: map()) :: map()
      @callback get_calendar_api_module() :: module()
      @callback call_list_events(
                  integration :: term(),
                  start_time :: DateTime.t(),
                  end_time :: DateTime.t()
                ) :: term()
      @callback call_create_event(integration :: term(), event_attrs :: map()) :: term()
      @callback call_update_event(
                  integration :: term(),
                  event_id :: String.t(),
                  event_attrs :: map()
                ) :: term()
      @callback call_delete_event(integration :: term(), event_id :: String.t()) :: term()

      # Helper functions for providers
      defp default_start_time, do: OAuthBase.default_start_time()
      defp default_end_time, do: OAuthBase.default_end_time()
    end
  end
end
