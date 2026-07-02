defmodule Tymeslot.Agenda do
  @moduledoc """
  Builds the dashboard agenda: a merged, deduplicated view of the user's
  upcoming Tymeslot bookings and synced external calendar events.

  The result (`Agenda.Day`) surfaces the next appointment as a hero and groups
  the rest into Today and Tomorrow, all in the user's timezone. This is a
  cross-domain read that orchestrates the `Meetings` and calendar contexts — it
  owns no storage of its own.
  """

  alias Tymeslot.Agenda.Day
  alias Tymeslot.Agenda.Entry
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Meetings
  alias Tymeslot.Utils.DateTimeUtils

  # How far ahead to look for the hero when nothing is scheduled today/tomorrow.
  @lookahead_days 31
  @default_timezone "Etc/UTC"
  # Upper bound on confirmed bookings pulled in — far more than a two-day agenda
  # plus a hero fallback ever needs.
  @meeting_limit 100
  # Upper bound on cached external calendar events pulled in for the lookahead
  # window — far more than a two-day agenda plus a hero fallback ever needs,
  # but wide enough to absorb a busy calendar's recurring-event instances.
  @external_event_limit 300

  @doc """
  Assembles the Today/Tomorrow agenda for `user` in `timezone`.

  `user` needs `:id` (to resolve calendar integrations) and `:email` (to resolve
  bookings). A nil/blank/unknown timezone falls back to UTC.
  """
  @spec day_agenda(map(), String.t() | nil) :: Day.t()
  def day_agenda(user, timezone) do
    now = DateTime.utc_now()
    tz = normalize_timezone(timezone)
    today = to_local_date(now, tz)
    tomorrow = Date.add(today, 1)
    window_end = DateTime.add(now, @lookahead_days * 86_400, :second)

    integrations = active_integrations(user)
    integration_ids = Enum.map(integrations, & &1.id)
    calendar_names = Map.new(integrations, &{&1.id, &1.name})

    entries =
      user
      |> gather_entries(integration_ids, calendar_names, now, window_end, tz)
      |> Enum.filter(&upcoming?(&1, now))
      |> Enum.sort_by(& &1.start_at, DateTime)

    {next, rest} = pop_hero(entries)

    %Day{
      next: next,
      today: Enum.filter(rest, &Entry.covers?(&1, today, tz)),
      tomorrow: Enum.filter(rest, &Entry.covers?(&1, tomorrow, tz)),
      has_calendar?: integration_ids != [],
      later?: next != nil and Date.after?(next.day, tomorrow),
      timezone: tz
    }
  end

  # --- Gathering & merging ---------------------------------------------------

  defp gather_entries(user, integration_ids, calendar_names, now, window_end, tz) do
    # The `/2` query filters to confirmed bookings; `/1` would include pending
    # and cancelled ones, which have no place on the agenda.
    meetings = Meetings.list_upcoming_meetings_for_user(user.email, @meeting_limit)

    # Bookings synced to the calendar reappear as provider events; dedup on the
    # provider event id so the (richer) Tymeslot copy is the one we keep.
    booked_event_ids =
      meetings
      |> Enum.map(& &1.provider_event_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    external =
      integration_ids
      |> CalendarGrid.list_events_for_range(now, window_end, limit: @external_event_limit)
      |> Enum.reject(&drop_external?(&1, booked_event_ids))

    Enum.map(meetings, &entry_from_meeting(&1, tz)) ++
      Enum.map(external, &entry_from_event(&1, tz, calendar_names))
  end

  # An external event is dropped when it is one of our own synced bookings, a
  # cancellation, a free/transparent block, or a timed event missing its start.
  defp drop_external?(event, booked_event_ids) do
    event.created_by_tymeslot or
      event.status == "cancelled" or
      event.transparency == "transparent" or
      (not event.all_day and is_nil(event.start_at)) or
      (not is_nil(event.provider_event_id) and
         MapSet.member?(booked_event_ids, event.provider_event_id))
  end

  # The hero is the next *timed* entry; all-day entries stay in their day group.
  defp pop_hero(entries) do
    case Enum.find(entries, &(not &1.all_day?)) do
      nil -> {nil, entries}
      hero -> {hero, List.delete(entries, hero)}
    end
  end

  defp upcoming?(%Entry{end_at: end_at}, now), do: DateTime.compare(end_at, now) == :gt

  # --- Normalisation ---------------------------------------------------------

  defp entry_from_meeting(meeting, tz) do
    %Entry{
      id: "meeting-" <> to_string(meeting.id),
      source: :tymeslot,
      title: presence(meeting.title) || "Meeting",
      day: to_local_date(meeting.start_time, tz),
      start_at: meeting.start_time,
      end_at: meeting.end_time,
      all_day?: false,
      location: presence(meeting.location),
      join_url: presence(meeting.organizer_video_url) || presence(meeting.meeting_url),
      who: presence(meeting.attendee_name),
      calendar: nil
    }
  end

  defp entry_from_event(%{all_day: true} = event, tz, calendar_names) do
    end_date = event.end_date || Date.add(event.start_date, 1)

    %Entry{
      id: "event-" <> to_string(event.id),
      source: :external,
      title: presence(event.summary) || "Busy",
      day: event.start_date,
      start_at: local_midnight(event.start_date, tz),
      end_at: local_midnight(end_date, tz),
      all_day?: true,
      location: presence(event.location),
      join_url: nil,
      who: organiser_name(event.organiser),
      calendar: calendar_name(event, calendar_names)
    }
  end

  defp entry_from_event(event, tz, calendar_names) do
    end_at = event.end_at || DateTime.add(event.start_at, 3600, :second)

    %Entry{
      id: "event-" <> to_string(event.id),
      source: :external,
      title: presence(event.summary) || "Busy",
      day: to_local_date(event.start_at, tz),
      start_at: event.start_at,
      end_at: end_at,
      all_day?: false,
      location: presence(event.location),
      join_url: presence(event.video_link),
      who: organiser_name(event.organiser),
      calendar: calendar_name(event, calendar_names)
    }
  end

  # --- Helpers ---------------------------------------------------------------

  defp active_integrations(%{id: id}) when is_integer(id) do
    id
    |> Calendar.list_integrations()
    |> Enum.filter(& &1.is_active)
  end

  defp active_integrations(_user), do: []

  defp calendar_name(%{calendar_integration_id: id}, calendar_names),
    do: presence(Map.get(calendar_names, id))

  defp calendar_name(_event, _calendar_names), do: nil

  defp to_local_date(datetime, tz) do
    datetime
    |> DateTimeUtils.convert_to_timezone(tz)
    |> DateTime.to_date()
  end

  # Total by construction: midnight can be a DST gap or ambiguous in some zones,
  # and an all-day chip must never crash the dashboard.
  defp local_midnight(date, tz) do
    case DateTime.new(date, ~T[00:00:00], tz) do
      {:ok, datetime} -> datetime
      {:ambiguous, first, _second} -> first
      {:gap, _just_before, just_after} -> just_after
      {:error, _reason} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp organiser_name(organiser) when is_map(organiser) do
    presence(organiser["displayName"]) || presence(organiser["name"]) ||
      presence(organiser["email"]) || presence(organiser[:displayName]) ||
      presence(organiser[:name]) || presence(organiser[:email])
  end

  defp organiser_name(_organiser), do: nil

  defp normalize_timezone(tz) when is_binary(tz) and tz != "" do
    case DateTime.now(tz) do
      {:ok, _dt} -> tz
      _error -> @default_timezone
    end
  end

  defp normalize_timezone(_tz), do: @default_timezone

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
