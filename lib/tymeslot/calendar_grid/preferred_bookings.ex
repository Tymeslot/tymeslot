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

  The organiser may give a copy a repeat rule. The booking still stands for
  the copy's own date, but not for the series' later occurrences, previewed
  until a sync caches them (`Tymeslot.Integrations.Calendar.SeriesPreview`),
  so those stay. On the CalDAV family the sync then caches every occurrence,
  the copy's own date included, under the copy's UID and the slot's key and
  under the series' href, neither of which the booking carries; the
  occurrence on the booking's own slot is matched as its copy instead, and
  the later ones stay.
  """

  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Calendar.SeriesPreview
  alias Tymeslot.Meetings.ExternalCalendar

  @doc """
  `visible` (the cached events the calendar selection keeps) less the copies
  of `bookings`, followed by `bookings` with their `copy` filled from
  `cached` (every cached row of the window, visible or not). A visible copy
  is named in preference to a hidden one.
  """
  @spec merge([map()], [map()], [BookingEvent.t()], [map()]) :: [map()]
  def merge(visible, cached, bookings, integrations) do
    copies = [index(visible), index(cached)]
    visible_occurrences = occurrence_index(visible)
    occurrences = [visible_occurrences, occurrence_index(cached)]
    bookings = Enum.map(bookings, &with_copy(&1, copies, occurrences, integrations))
    mirrored = ExternalCalendar.calendar_identifier_set(bookings)

    first_dates =
      bookings
      |> Enum.map(&first_date_copy(&1, visible_occurrences))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(visible, &(copy_of_booking?(&1, mirrored) or MapSet.member?(first_dates, &1))) ++
      bookings
  end

  defp copy_of_booking?(event, mirrored),
    do:
      not SeriesPreview.preview?(event) and
        ExternalCalendar.linked_to_calendar_event?(event, mirrored)

  # Every identifier of every row, pointing at the first row that has it.
  defp index(rows) do
    rows
    |> Enum.reject(&SeriesPreview.preview?/1)
    |> Enum.reduce(%{}, fn row, acc ->
      row
      |> ExternalCalendar.calendar_event_identifiers()
      |> Enum.reduce(acc, &Map.put_new(&2, &1, row))
    end)
  end

  # The cached occurrences of CalDAV-family series, by the instant they
  # start: an occurrence's uid is its series' UID, an underscore and the
  # slot's key.
  defp occurrence_index(rows) do
    rows
    |> Enum.filter(&series_occurrence?/1)
    |> Enum.group_by(&DateTime.to_unix(&1.start_at, :microsecond))
  end

  defp series_occurrence?(row),
    do:
      not SeriesPreview.preview?(row) and
        ProviderConfig.resource_series?(Map.get(row, :provider)) and
        is_binary(Map.get(row, :uid)) and match?(%DateTime{}, Map.get(row, :start_at))

  # The occurrence on the booking's own slot of the series its copy became.
  defp first_date_copy(%{uid: uid, start_at: %DateTime{} = start_at}, occurrences)
       when is_binary(uid) and uid != "" do
    occurrences
    |> Map.get(DateTime.to_unix(start_at, :microsecond), [])
    |> Enum.find(&String.starts_with?(&1.uid, uid <> "_"))
  end

  defp first_date_copy(_booking, _occurrences), do: nil

  # The first index (visible rows) that knows any of the booking's
  # identifiers wins, so a visible copy is named before a hidden one; failing
  # any, the occurrence on the booking's slot, visible before hidden.
  defp with_copy(booking, copies, occurrences, integrations) do
    identifiers = ExternalCalendar.calendar_event_identifiers(booking)

    row =
      Enum.find_value(copies, fn index ->
        Enum.find_value(identifiers, &Map.get(index, &1))
      end) || Enum.find_value(occurrences, &first_date_copy(booking, &1))

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
