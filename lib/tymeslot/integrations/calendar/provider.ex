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

  @callback normalise_events(raw_events :: [map()], context :: context()) ::
              {:ok, [CalendarEvent.t()]} | {:error, term()}
end
