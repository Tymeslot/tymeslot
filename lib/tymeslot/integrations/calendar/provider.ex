defmodule Tymeslot.Integrations.Calendar.Provider do
  @moduledoc """
  Behaviour that all calendar providers must implement.

  Each provider normalises raw API responses into canonical `CalendarEvent` structs.
  Validation happens inside each provider via `CalendarEvent.new!/1` — if a provider
  produces an invalid event, it fails loudly at normalisation time.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent

  @type context :: %{
          calendar_integration_id: integer(),
          provider_calendar_id: String.t(),
          synced_at: DateTime.t()
        }

  @doc """
  Creates a new client instance for the provider.
  """
  @callback new(config :: map()) :: any()

  @doc """
  Creates a new event in the calendar.
  """
  @callback create_event(client :: any(), event_data :: map()) :: {:ok, any()} | {:error, any()}

  @doc """
  Updates an existing event in the calendar.
  """
  @callback update_event(client :: any(), uid :: String.t(), event_data :: map()) ::
              :ok | {:ok, any()} | {:error, any()}

  @doc """
  Deletes an event from the calendar.

  `opts` may carry a `:provider_event_id` (the event's canonical server-side
  identifier). CalDAV providers use it to route the DELETE to the calendar
  that actually holds the event, rather than defaulting to the first
  configured calendar path.
  """
  @callback delete_event(client :: any(), uid :: String.t(), opts :: keyword()) ::
              :ok | {:ok, any()} | {:error, any()}

  @doc """
  Returns the provider type identifier.
  """
  @callback provider_type() :: atom()

  @doc """
  Returns the display name for this provider.
  """
  @callback display_name() :: String.t()

  @doc """
  Returns the configuration schema for this provider.
  """
  @callback config_schema() :: map()

  @doc """
  Validates the provider configuration.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, String.t()}

  @callback normalise_events(raw_events :: [map()], context :: context()) ::
              {:ok, [CalendarEvent.t()]} | {:error, term()}

  @doc """
  Performs a quick connectivity probe for the provider.

  CalDAV providers should verify reachability and authentication.
  OAuth providers may return `{:ok, %{status: :skipped}}` immediately since
  token validity is checked lazily on the first real API call.
  """
  @callback check_connectivity(client :: any()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Lists events from the provider within a date range.

  Unified entry point that works for both CalDAV and OAuth providers.
  Opts must include `:start_time` and `:end_time` as `DateTime.t()` values.
  """
  @callback list_events(client :: any(), opts :: keyword()) ::
              {:ok, list()} | {:error, any()}

  @doc """
  Discovers the user's calendars given a persisted integration.

  Unified entry point for the dashboard's "discover calendars" flow. CalDAV
  providers decrypt the stored credentials and probe the configured server;
  OAuth providers issue the appropriate API call against the stored token.
  Returns a list of provider-shaped calendar maps — `Shared.DiscoveryService`
  callers normalise these via `standardize_calendar_data/2`.

  Optional: providers that do not support discovery (e.g. demo/debug)
  may omit this callback.
  """
  @callback discover_calendars_for_integration(integration :: map()) ::
              {:ok, list(map())} | {:error, term()}

  @doc """
  Builds the list of provider-specific client configs for an integration.

  Used by `Runtime.ClientManager` to construct adapter clients for sync,
  multi-calendar fetch, and any flow that iterates over every calendar the
  user has selected. OAuth providers typically return `[integration]` (the
  integration struct itself is the client); CalDAV providers return one
  config map per selected calendar path.
  """
  @callback build_client_configs(integration :: map()) :: [any()]

  @doc """
  Builds a single provider-specific client config for the booking flow.

  Returns `nil` when no suitable client can be constructed — for example,
  a CalDAV integration with no resolvable booking path. OAuth providers
  typically return the integration struct directly.
  """
  @callback build_booking_client_config(integration :: map()) :: any() | nil

  @optional_callbacks discover_calendars_for_integration: 1,
                      build_client_configs: 1,
                      build_booking_client_config: 1
end
