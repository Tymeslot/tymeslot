defmodule Tymeslot.CalendarGrid.EventSearch do
  @moduledoc """
  The calendar's search, behind its command bar
  (`Tymeslot.CalendarGrid.search_calendar/5`).

  Finds the organiser's cached calendar events and bookings for a typed
  term and returns them as hits the bar can draw and the grid can reveal:

    * Nearest first: what is ahead in ascending order, then what has passed,
      latest first, so this week's "Standup" beats last year's.
    * The cache holds a repeating series as one row per occurrence, so the
      occurrences collapse to one hit, the nearest (`series: true`).
    * Only what the grid would show: the effective visibility (hidden
      accounts, hidden calendars, the active set) applies to calendar rows;
      bookings are never hidden, as on the grid.
    * The grid draws a booking in place of the calendar copy Tymeslot wrote
      for it (`PreferredBookings`), so a hit on a copy becomes the booking's
      hit, and a booking found both ways is listed once.
  """

  alias Tymeslot.CalendarGrid.EffectiveVisibility
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSearchQueries
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.ExternalCalendar

  @min_length 2
  @max_length 100
  @default_limits %{events: 8, bookings: 5}
  # Calendar rows fetched per side for each event shown: a series' other
  # occurrences and rows in hidden calendars are dropped after the query.
  @overfetch 3

  @type hit :: %{
          id: String.t(),
          ids: [String.t()],
          kind: :event | :booking,
          title: String.t(),
          start: DateTime.t() | Date.t(),
          finish: DateTime.t() | Date.t(),
          all_day: boolean(),
          series: boolean(),
          calendar_integration_id: integer() | nil,
          provider_calendar_id: String.t() | nil,
          meeting_type: String.t() | nil
        }

  @doc """
  Searches `user_id`'s events and bookings for `term`. `integrations` are
  the organiser's active integrations (their calendar selection is applied
  in the query); `visibility` is what the organiser has hidden. Options:
  `:now` (required), `:limit` (`%{events: 8, bookings: 5}` by default; either
  key may be given alone). A trimmed term under two characters returns
  empty lists without a query.
  """
  @spec search(integer(), String.t(), [map()], EffectiveVisibility.t(), keyword()) ::
          %{events: [hit()], bookings: [hit()]}
  def search(user_id, term, integrations, %EffectiveVisibility{} = visibility, opts) do
    trimmed = term |> to_string() |> String.trim() |> String.slice(0, @max_length)

    if String.length(trimmed) < @min_length do
      %{events: [], bookings: []}
    else
      now = Keyword.fetch!(opts, :now)
      limits = Map.merge(@default_limits, Keyword.get(opts, :limit, %{}))
      rows = calendar_rows(user_id, trimmed, integrations, visibility, now, limits.events)
      {copied, events} = split_copies(rows, user_id)
      found = Meetings.search_for_organizer(user_id, trimmed, from: now, limit: limits.bookings)

      %{
        events:
          events
          |> Enum.uniq_by(&series_key/1)
          |> Enum.map(&event_hit/1)
          |> nearest_first(now, limits.events),
        bookings:
          (found.upcoming ++ found.past ++ copied)
          |> Enum.map(&booking_hit/1)
          |> nearest_first(now, limits.bookings)
      }
    end
  end

  # Upcoming rows (ascending) then past rows (latest first): the order
  # `Enum.uniq_by/2` relies on to keep a series' nearest occurrence.
  defp calendar_rows(user_id, term, integrations, visibility, now, limit) do
    %{upcoming: upcoming, past: past} =
      ProviderCalendarEventSearchQueries.search_around(user_id, term,
        from: now,
        limit: limit * @overfetch,
        hidden_integration_ids: visibility.hidden_integration_ids,
        visibility_rules: Calendar.visibility_rules(integrations)
      )

    EffectiveVisibility.reject(upcoming ++ past, visibility)
  end

  # Splits the rows into the bookings some of them are copies of, and the
  # rest. One identifier query per integration.
  defp split_copies(rows, user_id) do
    linked = linked_bookings(rows, user_id)
    {copies, events} = Enum.split_with(rows, &Map.has_key?(linked, &1.id))
    {Enum.map(copies, &Map.fetch!(linked, &1.id)), events}
  end

  # Row id => the booking that row is the calendar copy of, for bookings the
  # grid draws in its place (a live slot, or a request that expired
  # unanswered; a cancelled booking's copy, should one linger, is drawn as
  # itself, which the identifier query's `drawn_for` leaves out).
  defp linked_bookings(rows, user_id) do
    rows
    |> Enum.group_by(& &1.calendar_integration_id)
    |> Enum.flat_map(fn {integration_id, group} ->
      by_identifier =
        ExternalCalendar.list_meetings_by_calendar_identifiers(
          integration_id,
          Enum.flat_map(group, &ExternalCalendar.calendar_event_identifiers/1),
          drawn_for: user_id
        )

      Enum.flat_map(group, fn row ->
        meeting =
          Enum.find_value(
            ExternalCalendar.calendar_event_identifiers(row),
            &Map.get(by_identifier, &1)
          )

        if meeting, do: [{row.id, meeting}], else: []
      end)
    end)
    |> Map.new()
  end

  defp series_key(row) do
    case Occurrence.series_address(row) do
      {:ok, address} -> {:series, row.calendar_integration_id, address}
      {:error, _unaddressable} -> {:row, row.id}
    end
  end

  defp event_hit(row) do
    id = EventPayload.id(row)
    {start, finish} = span(row)

    %{
      id: id,
      ids: [id],
      kind: :event,
      title: EventPayload.title(row),
      start: start,
      finish: finish,
      all_day: row.all_day,
      series: EventPayload.recurring?(row) or match?({:series, _, _}, series_key(row)),
      calendar_integration_id: row.calendar_integration_id,
      provider_calendar_id: row.provider_calendar_id,
      meeting_type: nil
    }
  end

  defp span(%{all_day: true, start_date: first} = row),
    do: {first, EventPayload.exclusive_end(row)}

  defp span(row), do: {row.start_at, row.end_at}

  defp booking_hit(meeting) do
    id = "booking-#{meeting.id}"

    %{
      id: id,
      ids: [id],
      kind: :booking,
      title: booking_title(meeting),
      start: meeting.start_time,
      finish: meeting.end_time,
      all_day: false,
      series: false,
      calendar_integration_id: nil,
      provider_calendar_id: nil,
      meeting_type: meeting.meeting_type
    }
  end

  # The title the grid gives the booking: a one-to-one booking leads with its
  # guest; a group booking keeps its own title.
  defp booking_title(meeting) do
    if Meetings.group?(meeting),
      do: EventPayload.title(%{summary: meeting.title}),
      else:
        EventPayload.title(%{
          kind: :booking,
          participants: [],
          attendee_name: meeting.attendee_name,
          meeting_type: meeting.meeting_type,
          summary: meeting.title
        })
  end

  defp nearest_first(hits, now, limit) do
    {upcoming, past} = Enum.split_with(hits, &(DateTime.compare(sort_key(&1), now) != :lt))

    (Enum.sort_by(upcoming, &sort_key/1, DateTime) ++
       Enum.sort_by(past, &sort_key/1, {:desc, DateTime}))
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(limit)
  end

  # All-day rows divide at midnight UTC, as the query's `coalesce` does.
  defp sort_key(%{start: %DateTime{} = start}), do: start
  defp sort_key(%{start: %Date{} = start}), do: DateTime.new!(start, ~T[00:00:00], "Etc/UTC")
end
