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
  """
  @callback delete_event(client :: any(), uid :: String.t()) ::
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
end
