defmodule Tymeslot.Integrations.Calendar.Provider do
  @moduledoc """
  Behaviour that all calendar providers must implement.

  Each provider normalises raw API responses into canonical `CalendarEvent` structs.
  Validation happens inside each provider via `CalendarEvent.new!/1` — if a provider
  produces an invalid event, it fails loudly at normalisation time.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Shared.ConnectionProbe

  @type context :: %{
          calendar_integration_id: integer(),
          provider_calendar_id: String.t(),
          synced_at: DateTime.t()
        }

  @typedoc """
  The shape `validate_config/1` and `perform_connection_test/1` are called with.

  CalDAV-family providers read a plain, atom-keyed map (built by
  `Calendar.Creation.prevalidate_config/1` for a not-yet-persisted
  integration, or by `CalendarIntegrationSchema.to_provider_config/1` for an
  already-persisted one) via bracket access. OAuth providers instead read the
  persisted `CalendarIntegrationSchema` struct directly, via dot/`Map`
  access. `Calendar.Connection.probe/3` is the single choke point both
  shapes flow through.
  """
  @type config :: map() | CalendarIntegrationSchema.t()

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
  Returns the connection-test rate-limit bucket this provider draws its
  budget from, or `:unmetered` for providers whose connection test must
  deliberately run without charging (dev-only providers, whose test never
  reaches a real external service). There is no default implementation:
  every provider must declare a bucket explicitly, so a new provider that
  omits it fails `mix compile --warnings-as-errors` instead of silently
  running unmetered.
  """
  @callback connection_test_bucket() :: ConnectionProbe.bucket()

  @doc """
  Returns the configuration schema for this provider.
  """
  @callback config_schema() :: map()

  @doc """
  Validates the provider configuration.

  Structural validation only; never performs network I/O.
  `Calendar.Connection.probe/3` runs this first and then `perform_connection_test/1`
  — folding the network probe into this callback would double-charge a
  rate-limited connection test that runs both in sequence.
  """
  @callback validate_config(config :: config()) :: :ok | {:error, String.t()}

  @doc """
  Tests connectivity to the provider using the given config.

  Pure I/O: this callback never rate-limits itself. The single choke point
  for connection-test rate limiting is
  `Tymeslot.Integrations.Calendar.Connection.test_connection/2`, which decides
  whether and to whom the test is charged before calling this.

  Named `perform_connection_test/1` rather than `test_connection/1` so a
  direct provider call reads as out-of-band — the human-facing name
  `test_connection` is reserved for the facade
  (`Tymeslot.Integrations.Calendar.test_connection/2`) and
  `Tymeslot.Integrations.Calendar.Connection`, the only legitimate callers of
  this callback; `CredoChecks.ConnectionProbeBoundary` enforces that
  mechanically.
  """
  @callback perform_connection_test(config :: config()) :: {:ok, String.t()} | {:error, term()}

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
  Declares which representation `list_events/2` hands back.

  `:raw` is the provider's own wire format, the shape its own
  `normalise_events/2` parses: iCalendar text for the CalDAV family, decoded
  API payloads for the OAuth providers. Pairing the two callbacks is only
  valid for these.

  `:normalised` means `list_events/2` has already mapped its events into the
  plain-map shape the availability path consumes. Cache-backed providers
  return this: they read the local event cache rather than the network (see
  `Tymeslot.Integrations.Calendar.Ics.Provider`), so there is no raw payload
  left to parse and feeding the result to `normalise_events/2` would fail
  deep inside a parser.

  There is no default implementation: every provider must declare its
  representation explicitly, so a new provider that omits it fails
  `mix compile --warnings-as-errors` instead of being silently assumed raw.
  """
  @callback list_events_representation() :: :raw | :normalised

  @doc """
  Discovers the user's calendars given a persisted integration.

  Unified entry point for the dashboard's "discover calendars" flow. CalDAV
  providers decrypt the stored credentials and probe the configured server;
  OAuth providers issue the appropriate API call against the stored token.
  Returns standardised `CalendarEntry` structs.

  Optional: providers that do not support discovery (e.g. demo/debug)
  may omit this callback.
  """
  @callback discover_calendars_for_integration(integration :: map()) ::
              {:ok, [CalendarEntry.t()]} | {:error, term()}

  @doc """
  Discovers raw calendars from a client built via `new/1`.

  Pure I/O: never rate-limits or caches itself. The single choke point for
  discovery metering and caching is
  `Tymeslot.Integrations.Calendar.Discovery`, which wraps a call to this
  callback (indirectly, via `discover_calendars_for_integration/1`, or
  directly for not-yet-persisted credentials) in the `:discovery`
  `ConnectionProbe` bucket.

  Optional: only implemented by CalDAV-family providers, whose
  `new/1` + `discover_calendars/1` pair this callback names directly. OAuth
  providers implement `discover_calendars_for_integration/1` against a fixed
  vendor endpoint instead and never go through this pair.
  """
  @callback discover_calendars(client :: any()) ::
              {:ok, [map()] | [CalendarEntry.t()]} | {:error, term()}

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
                      discover_calendars: 1,
                      build_client_configs: 1,
                      build_booking_client_config: 1
end
