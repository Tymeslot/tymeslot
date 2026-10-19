defmodule Tymeslot.Integrations.Calendar.Providers.OAuthBase do
  @moduledoc """
  Common OAuth functionality for calendar providers.

  This module provides shared OAuth configuration, validation, and utility functions
  that are common across different OAuth-based calendar providers like Google and Outlook.
  """

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Workers.RetryHelpers

  require Logger

  # Type definitions
  @type oauth_config :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          token_expires_at: DateTime.t(),
          oauth_scope: String.t()
        }

  @doc """
  Provides the common OAuth configuration schema used by all OAuth providers.
  """
  @spec config_schema() :: map()
  def config_schema do
    %{
      access_token: %{type: :string, required: true},
      refresh_token: %{type: :string, required: true},
      token_expires_at: %{type: :datetime, required: true},
      oauth_scope: %{type: :string, required: true}
    }
  end

  @doc """
  Validates OAuth configuration ensuring all required fields are present.

  Delegates to provider-specific OAuth scope validation if all required fields are present.
  """
  @spec validate_config(map(), (map() -> :ok | {:error, String.t()})) ::
          :ok | {:error, String.t()}
  def validate_config(config, scope_validator_fn) when is_function(scope_validator_fn, 1) do
    required_fields = [:access_token, :refresh_token, :token_expires_at, :oauth_scope]

    with :ok <- ProviderConfigHelper.validate_required_fields(config, required_fields) do
      scope_validator_fn.(config)
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

  @doc """
  Runs a create through `handle_api_call/2` and reports the provider's answer
  as a `CreatedEvent`.

  The OAuth providers mint their own event id, so the result carries it as the
  `provider_event_id` and no iCalendar uid, and keeps the converted response
  for the caller that reads a conference link out of it.
  """
  @spec handle_create((-> any()), (any() -> map())) ::
          {:ok, CreatedEvent.t()} | {:error, any()} | :ok
  def handle_create(api_call_fn, conversion_fn)
      when is_function(api_call_fn, 0) and is_function(conversion_fn, 1) do
    handle_api_call(api_call_fn, fn raw ->
      raw |> conversion_fn.() |> CreatedEvent.from_provider_event()
    end)
  end

  # A rate limit whose answer said how long to wait keeps the wait, as
  # `{:rate_limited, seconds}`, so `CalendarEventWorker` can snooze for it.
  # Callers that do not care still get a two-element error.
  defp log_typed_error(:rate_limited, message) do
    Logger.warning("Calendar provider API call failed", error_type: :rate_limited)

    case RetryHelpers.parse_retry_after_from_message(message) do
      seconds when is_integer(seconds) -> {:error, {:rate_limited, seconds}}
      nil -> {:error, :rate_limited}
    end
  end

  defp log_typed_error(type, message) do
    Logger.warning("Calendar provider API call failed",
      error_type: type,
      reason: LogFormat.reason(message)
    )

    {:error, type}
  end

  @doc """
  Macro for creating OAuth-based calendar providers.

  This macro injects common OAuth functionality while allowing providers
  to customize their specific behavior through the callbacks of
  `Tymeslot.Integrations.Calendar.Providers.OAuthProvider`.
  """
  defmacro __using__(opts) do
    provider_name = Keyword.fetch!(opts, :provider_name)
    display_name = Keyword.fetch!(opts, :display_name)
    base_url = Keyword.fetch!(opts, :base_url)

    quote do
      @behaviour Tymeslot.Integrations.Calendar.Provider
      @behaviour Tymeslot.Integrations.Calendar.Providers.OAuthProvider

      alias Tymeslot.Integrations.Calendar.Providers.OAuthBase

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
        OAuthBase.handle_create(
          fn -> call_create_event(integration, event_attrs) end,
          &convert_event/1
        )
      end

      # A split series answers with the new series it made, which is not an
      # event of the provider's to convert.
      @impl Tymeslot.Integrations.Calendar.Provider
      def update_event(integration, event_id, event_attrs) do
        OAuthBase.handle_api_call(
          fn -> call_update_event(integration, event_id, event_attrs) end,
          fn
            %{tail: _tail} = split -> split
            updated -> convert_event(updated)
          end
        )
      end

      # `opts` reaches the provider rather than being dropped here. It carries
      # the calendar the event is actually on, which create and update already
      # read off `event_attrs[:calendar_id]`; with no channel for it, a delete
      # could only ever address the default booking calendar, so deleting an
      # event on any other calendar aimed at a resource that is not there.
      @impl Tymeslot.Integrations.Calendar.Provider
      def delete_event(integration, event_id, opts) do
        OAuthBase.handle_api_call(fn -> call_delete_event(integration, event_id, opts) end)
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
    end
  end
end
