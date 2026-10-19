defmodule Tymeslot.CalendarGrid.EventBlocking do
  @moduledoc """
  Whether a cached calendar row takes bookable time, decided as availability
  decides it (`Tymeslot.FreeBusy.busy_intervals/3`): an integration that
  counts every event as busy (`all_events_busy`) overrides the row's
  transparency, then `CalendarEvent.blocking?/1` drops declined and cancelled
  events, free ones, and timed events that end the instant they start.

  The calendar's own "show only" choice is a separate question, answered by
  `Tymeslot.Integrations.Calendar.Blocking.blocks?/2`.
  """

  alias Tymeslot.Availability.Bookability
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  @doc "True when the cached `row`, on `integration`, blocks availability."
  @spec blocks?(ProviderCalendarEventSchema.t(), map() | nil) :: boolean()
  def blocks?(%ProviderCalendarEventSchema{} = row, integration) do
    event = ProviderCalendarEventSchema.to_calendar_event(row)

    event =
      if integration && Map.get(integration, :all_events_busy) == true,
        do: CalendarEvent.as_busy(event),
        else: event

    CalendarEvent.blocking?(event)
  end

  @doc """
  Whether the cached `row`, on a read-only calendar, stops guests booking its
  time: the organiser's choice in `overrides` where there is one, otherwise
  `Bookability`'s default for such an event (an all-day one is busy even
  when marked free, a cancelled one is not).
  """
  @spec busy_on_read_only?(ProviderCalendarEventSchema.t(), Bookability.overrides()) :: boolean()
  def busy_on_read_only?(%ProviderCalendarEventSchema{} = row, overrides) do
    row
    |> ProviderCalendarEventSchema.to_calendar_event()
    |> Bookability.busy_for_bookings?(true, overrides)
  end
end
