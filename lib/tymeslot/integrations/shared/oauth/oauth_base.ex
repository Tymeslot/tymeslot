defmodule Tymeslot.Integrations.Common.OAuthBase do
  @moduledoc """
  Common OAuth functionality for calendar providers.

  This module provides shared OAuth configuration, validation, and utility functions
  that are common across different OAuth-based calendar providers like Google and Outlook.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.PrimarySelection
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

  Provider API modules classify a failure as `{:error, type, message}`: an atom
  the caller can act on, plus a human-readable detail. Everything above this
  layer dispatches on the atom — `CalendarEventSync` recreates an event on
  `{:error, :not_found}`, and `CalendarEventWorker` classifies `:unauthorized`,
  `:rate_limited` and `:not_found` into discard/snooze/success outcomes — so
  the atom is what propagates. The message would be indistinguishable from any
  other opaque string at those call sites, so it is logged here rather than
  returned. CalDAV providers already answer with `{:error, atom}`; this keeps
  both families speaking the same contract.
  """
  @spec handle_api_call((-> any()), (any() -> any())) :: {:ok, any()} | {:error, any()} | :ok
  def handle_api_call(api_call_fn, conversion_fn \\ &Function.identity/1)
      when is_function(api_call_fn, 0) and is_function(conversion_fn, 1) do
    case api_call_fn.() do
      {:ok, result} -> {:ok, conversion_fn.(result)}
      :ok -> :ok
      {:error, type, message} -> log_typed_error(type, message)
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_typed_error(type, message) do
    Logger.warning("Calendar provider API call failed",
      error_type: type,
      reason: inspect(message)
    )

    {:error, type}
  end

  @doc """
  Creates or updates a calendar integration in the database.

  This handles the common pattern of checking if an integration exists and either
  creating or updating it accordingly.
  """
  @spec create_or_update_integration(integer(), String.t(), %{atom() => term()}, oauth_tokens()) ::
          {:ok, any()} | {:error, any()}
  def create_or_update_integration(user_id, provider_name, provider_config, tokens) do
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

        PrimarySelection.create_with_auto_primary(attrs)

      {:ok, existing_integration} ->
        attrs = %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          token_expires_at: tokens.expires_at,
          oauth_scope: tokens.scope,
          is_active: true
        }

        CalendarIntegrationQueries.update_credentials(existing_integration, attrs)
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
      @behaviour Tymeslot.Integrations.Calendar.Provider

      alias Tymeslot.Integrations.Common.OAuthBase

      @provider_name unquote(provider_name)
      @display_name unquote(display_name)
      @base_url unquote(base_url)

      @impl Tymeslot.Integrations.Calendar.Provider
      def provider_type, do: String.to_existing_atom(@provider_name)

      @impl Tymeslot.Integrations.Calendar.Provider
      def display_name, do: @display_name

      # A per-actor bucket shared across every OAuth-backed provider: the
      # test itself rides on a token that is already scarce, but without a
      # charge here it is unbounded and can burn the instance-wide OAuth
      # quota shared by every user.
      @impl Tymeslot.Integrations.Calendar.Provider
      def connection_test_bucket, do: :oauth

      @impl Tymeslot.Integrations.Calendar.Provider
      def config_schema, do: OAuthBase.config_schema()

      @impl Tymeslot.Integrations.Calendar.Provider
      def new(config) do
        OAuthBase.new(config, &validate_oauth_scope/1)
      end

      @impl Tymeslot.Integrations.Calendar.Provider
      def validate_config(config) do
        OAuthBase.validate_config(config, &validate_oauth_scope/1)
      end

      @impl Tymeslot.Integrations.Calendar.Provider
      def create_event(integration, event_attrs) do
        OAuthBase.handle_api_call(
          fn -> call_create_event(integration, event_attrs) end,
          &convert_event/1
        )
      end

      @impl Tymeslot.Integrations.Calendar.Provider
      def update_event(integration, event_id, event_attrs) do
        OAuthBase.handle_api_call(
          fn -> call_update_event(integration, event_id, event_attrs) end,
          &convert_event/1
        )
      end

      @impl Tymeslot.Integrations.Calendar.Provider
      def delete_event(integration, event_id, _opts) do
        OAuthBase.handle_api_call(fn -> call_delete_event(integration, event_id) end)
      end

      @impl Tymeslot.Integrations.Calendar.Provider
      def check_connectivity(_client) do
        {:ok, %{status: :skipped, reason: "OAuth providers use token-based auth"}}
      end

      @impl Tymeslot.Integrations.Calendar.Provider
      def list_events(integration, opts) do
        start_time = opts[:start_time]
        end_time = opts[:end_time]
        call_list_events(integration, start_time, end_time)
      end

      @impl Tymeslot.Integrations.Calendar.Provider
      def list_events_representation, do: :raw

      # normalise_events/2 is intentionally not defaulted here — it is
      # provider-specific and must be implemented by each OAuth provider.

      defoverridable check_connectivity: 1, list_events: 2, list_events_representation: 0

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
