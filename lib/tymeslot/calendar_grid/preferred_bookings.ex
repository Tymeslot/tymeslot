defmodule Tymeslot.CalendarGrid.PreferredBookings do
  @moduledoc """
  The calendar draws a Tymeslot booking as the booking, never as
  the calendar copy Tymeslot wrote for it: the booking knows its guest, its
  meeting type and whether it is still a request, and its preview can act on
  it. `merge/4` drops each copy from the calendar events and records on the
  booking which calendar the copy sits in (`copy`), so the preview can still
  say where it went.

  A copy is matched to its booking by `Tymeslot.Meetings.CalendarEventLink`'s
  rule (any shared identifier). A copy on a calendar the organiser has
  deselected still matches: the booking stays on the grid, since it belongs
  to Tymeslot rather than to that calendar.
  """

  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Meetings

  @doc """
  `visible` (the cached events the calendar selection keeps) less the copies
  of `bookings`, followed by `bookings` with their `copy` filled from
  `cached` (every cached row of the window, visible or not). A visible copy
  is named in preference to a hidden one.
  """
  @spec merge([map()], [map()], [BookingEvent.t()], [map()]) :: [map()]
  def merge(visible, cached, bookings, integrations) do
    copies = [index(visible), index(cached)]
    bookings = Enum.map(bookings, &with_copy(&1, copies, integrations))
    mirrored = Meetings.calendar_identifier_set(bookings)

    Enum.reject(visible, &Meetings.linked_to_calendar_event?(&1, mirrored)) ++ bookings
  end

  # Every identifier of every row, pointing at the first row that has it.
  defp index(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      row
      |> Meetings.calendar_event_identifiers()
      |> Enum.reduce(acc, &Map.put_new(&2, &1, row))
    end)
  end

  # The first index (visible rows) that knows any of the booking's
  # identifiers wins, so a visible copy is named before a hidden one.
  defp with_copy(booking, copies, integrations) do
    identifiers = Meetings.calendar_event_identifiers(booking)

    row =
      Enum.find_value(copies, fn index ->
        Enum.find_value(identifiers, &Map.get(index, &1))
      end)

    case row do
      nil -> booking
      row -> %{booking | copy: copy(row, integrations)}
    end
  end

  defp copy(row, integrations) do
    integration = Enum.find(integrations, &(&1.id == row.calendar_integration_id))

    %{
      calendar_integration_id: row.calendar_integration_id,
      provider_calendar_id: Map.get(row, :provider_calendar_id),
      calendar_name: calendar_name(row, integration)
    }
  end

  defp calendar_name(_row, nil), do: nil

  defp calendar_name(row, integration) do
    entries = Enum.map(Map.get(integration, :calendar_list) || [], &CalendarEntry.normalize/1)

    case Selection.calendar_for_event(row, entries) do
      %CalendarEntry{name: name} when is_binary(name) and name != "" -> name
      _unnamed -> integration.name
    end
  end
end
