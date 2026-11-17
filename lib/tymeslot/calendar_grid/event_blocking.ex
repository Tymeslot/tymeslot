defmodule Tymeslot.CalendarGrid.EventBlocking do
  @moduledoc """
  Whether a cached calendar row takes bookable time, decided as availability
  decides it (`Tymeslot.FreeBusy.busy_intervals/3`): an integration that
  counts every event as busy (`all_events_busy`) overrides the row's
  transparency, then `CalendarEvent.blocking?/1` drops declined and cancelled
  events, free ones, and timed events that end the instant they start. The
  organiser's "Treat as" choice on an all-day event, where there is one,
  wins over that for bookings (`busy_for_bookings?/3`).

  The calendar's own "show only" choice is a separate question, answered by
  `Tymeslot.Integrations.Calendar.Blocking.blocks?/2`.
  """

  alias Tymeslot.Availability.Bookability
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  @doc "True when the cached `row`, on `integration`, blocks availability."
  @spec blocks?(ProviderCalendarEventSchema.t(), map() | nil) :: boolean()
  def blocks?(%ProviderCalendarEventSchema{} = row, integration) do
    row |> presented(integration) |> CalendarEvent.blocking?()
  end

  @doc """
  Whether the cached `row`, on `integration`, stops guests booking its time:
  the organiser's choice in `overrides` where there is one (all-day events
  only), otherwise `blocks?/2` (`Bookability.busy_for_bookings?/2`).
  """
  @spec busy_for_bookings?(ProviderCalendarEventSchema.t(), map() | nil, Bookability.overrides()) ::
          boolean()
  def busy_for_bookings?(%ProviderCalendarEventSchema{} = row, integration, overrides) do
    row |> presented(integration) |> Bookability.busy_for_bookings?(overrides)
  end

  defp presented(row, integration) do
    row
    |> ProviderCalendarEventSchema.to_calendar_event()
    |> Bookability.as_presented(integration)
  end
end
