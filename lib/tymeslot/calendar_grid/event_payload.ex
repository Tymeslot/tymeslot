defmodule Tymeslot.CalendarGrid.EventPayload do
  @moduledoc """
  The JSON the calendar's `CalendarCanvas` hook draws the grid from.

  Times are wall-clock strings in the organiser's zone (`"2026-10-16T09:30"`),
  never instants: the browser may sit in another zone, and the grid must show
  the organiser's day exactly as the booking engine reads it. All-day events
  carry dates, with the exclusive end they are stored with. Whether an event
  is past is left to the browser, which knows the minute it draws in.

  Event ids are prefixed by kind (`"event-42"`, `"booking-<uuid>"`), so a
  provider row and a booking can never collide in the hook's cache.

  `editable` says whether the organiser can change the event from the calendar
  (`EditGuard.editable?/2`); the hook offers dragging, resizing and deleting
  only on those, and the server checks again on every change. `movable`
  narrows that to the events whose time may change (`EditGuard.movable?/2`);
  `build/1` works it out for the whole window at once. `locked` says a group
  meeting with live seats sits on the event (`EditGuard.seat_locked?/2`, from
  the window's `locked_uids`): such an event is neither editable nor movable,
  and the grid marks it with a lock.

  Each event also names its calendar (`calendar`, `"<integration id>:<calendar
  id>"`, nil for bookings), whether it repeats (`recurring`) and how many
  guests it has (`guests`), and how those asked have answered (`replies`,
  `%{accepted, declined, total, label}` or nil). Drafts the organiser has not created yet (a
  create still saving, or the side panel's unsaved "New event") are drawn as
  `kind: "draft"` (`draft/4`), never editable or movable.

  An occurrence previewed from a series no sync has cached yet
  (`Tymeslot.Integrations.Calendar.SeriesPreview`) has an id of its own
  (`"preview-<series row id>-<slot key>"`), says so (`preview`) and is drawn
  waiting to sync (`attention`). It is never movable: it has no slot of its
  own on the calendar to move. It is editable when its series is, so E
  opens the series and Delete reaches the server, which refuses it with a
  word on why (`EditGuard`).

  A one-to-one booking's title leads with its guest and names its meeting
  type ("Anna Kowalski · Intro call"), or its own title without one, and every event says whether it is a
  booking request awaiting an answer (`request`) and whether that request
  expired unanswered (`expired`); both are false for anything but a booking.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.CalendarGrid.ColourTokens
  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.GuestReplies
  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.SeriesPreview

  @type context :: %{
          required(:timezone) => String.t(),
          required(:integration_tokens) => map(),
          required(:calendar_tokens) => map(),
          optional(:integrations) => [map()],
          optional(:movable_ids) => MapSet.t(String.t()),
          optional(:locked_uids) => MapSet.t(String.t()),
          optional(:colour_overrides) => map(),
          optional(atom()) => term()
        }

  @doc """
  The whole payload: the period, the loaded range (`to` exclusive), the
  organiser's current wall-clock minute, the display settings, whether the
  hook should drop everything it holds first (`reset`), and the events.
  `drafts` (optional) are `{draft_id, %CreateParams{}, pending?}` and follow
  the events.
  """
  @spec build(map()) :: map()
  def build(%{view: view, date: date, window: window, now: now, timezone: timezone} = input) do
    context = with_movable_ids(input)

    %{
      view: Atom.to_string(view),
      date: Date.to_iso8601(date),
      range: %{from: Date.to_iso8601(window.first), to: Date.to_iso8601(Date.add(window.last, 1))},
      now: format(local(now, timezone)),
      reset: input.reset,
      settings: input.settings,
      events:
        Enum.map(input.events, &event(&1, context)) ++
          Enum.map(Map.get(input, :drafts, []), fn {id, params, pending?} ->
            draft(id, params, pending?, context)
          end)
    }
  end

  # Which events may be moved is asked of the whole window at once, so the
  # booking-copy lookup behind it costs one query rather than one per event.
  # An event held by live seats is never among them.
  defp with_movable_ids(input) do
    locked = locked_uids(input)

    unlocked = Enum.reject(input.events, &EditGuard.seat_locked?(locked, &1))
    movable = EditGuard.movable(Map.get(input, :integrations, []), unlocked)

    Map.put(input, :movable_ids, MapSet.new(movable, &id/1))
  end

  @doc "One event in the payload's shape."
  @spec event(map(), context()) :: map()
  def event(event, context) do
    locked = EditGuard.seat_locked?(locked_uids(context), event)
    preview? = SeriesPreview.preview?(event)

    Map.merge(
      %{
        id: id(event),
        kind: kind(event),
        title: title(event),
        colour:
          event
          |> ColourTokens.with_override(Map.get(context, :colour_overrides, %{}))
          |> ColourTokens.for_event(context.integration_tokens, context.calendar_tokens),
        free: free?(event),
        attention: preview? or Map.get(event, :sync_state, "synced") != "synced",
        editable: editable?(SeriesPreview.series(event), context),
        movable: not locked and not preview? and movable?(event, context),
        preview: preview?,
        locked: locked,
        calendar: calendar_key(event),
        recurring: recurring?(event),
        guests: guest_count(event),
        replies: replies(event),
        request: Map.get(event, :request, false),
        expired: Map.get(event, :expired, false),
        tymeslot: Map.get(event, :created_by_tymeslot) == true
      },
      timing(event, context.timezone)
    )
  end

  @doc """
  A draft the organiser has not created yet, in an event's shape: a create
  still saving (`pending?` true, drawn "Saving…") or the side panel's unsaved
  "New event" draft. Its colour is its calendar's.
  """
  @spec draft(String.t(), CreateParams.t(), boolean(), context()) :: map()
  def draft(draft_id, %CreateParams{} = params, pending?, context) do
    row = %{
      calendar_integration_id: params.integration_id,
      provider_calendar_id: params.calendar_id
    }

    Map.merge(
      %{
        id: "draft-" <> draft_id,
        kind: "draft",
        title: params.title,
        colour: ColourTokens.for_event(row, context.integration_tokens, context.calendar_tokens),
        free: params.free,
        attention: false,
        editable: false,
        movable: false,
        locked: false,
        pending: pending?,
        calendar: draft_calendar(params),
        recurring: is_binary(params.recurrence_rule),
        guests: length(params.guests),
        replies: nil
      },
      draft_timing(params, context.timezone)
    )
  end

  # A meeting kept in Tymeslot alone is on no calendar.
  defp draft_calendar(%CreateParams{integration_id: nil}), do: nil

  defp draft_calendar(params),
    do: CalendarDirectory.key(params.integration_id, params.calendar_id)

  @doc "Whether `event` belongs to a repeating series: its master or one occurrence."
  @spec recurring?(map()) :: boolean()
  def recurring?(event),
    do:
      is_binary(Map.get(event, :recurrence_rule)) or
        is_binary(Map.get(event, :recurring_event_id))

  @doc "The id the hook knows an event by."
  @spec id(map()) :: String.t()
  def id(%{kind: :booking, id: id}), do: id
  def id(%{preview_of: %{id: id}, preview_key: key}), do: "preview-#{id}-#{key}"
  def id(%{id: id}), do: "event-#{id}"

  # An expired request holds no time, so it must not block the next free time.
  defp free?(event),
    do: Map.get(event, :transparency) == "transparent" or Map.get(event, :expired, false)

  @doc """
  The title the grid and the preview show. A one-to-one booking leads with
  its guest, then names its meeting type, or its own title when it has no
  meeting type; any other event keeps its own title.
  """
  @spec title(map()) :: String.t()
  def title(%{kind: :booking, participants: [], attendee_name: name, meeting_type: type})
      when is_binary(name) and name != "" and is_binary(type) and type != "",
      do: "#{name} · #{type}"

  def title(%{kind: :booking, participants: [], attendee_name: name, summary: summary})
      when is_binary(name) and name != "" do
    case summary |> to_string() |> String.trim() do
      "" -> name
      trimmed -> "#{name} · #{trimmed}"
    end
  end

  def title(%{summary: summary}) when is_binary(summary) do
    case String.trim(summary) do
      "" -> untitled()
      trimmed -> trimmed
    end
  end

  def title(_event), do: untitled()

  @doc "An all-day event's exclusive end date, one day when none usable is stored."
  @spec exclusive_end(map()) :: Date.t()
  def exclusive_end(%{start_date: %Date{} = first} = event) do
    case Map.get(event, :end_date) do
      %Date{} = last -> if Date.after?(last, first), do: last, else: Date.add(first, 1)
      _none -> Date.add(first, 1)
    end
  end

  defp calendar_key(%{kind: :booking}), do: nil

  defp calendar_key(%{calendar_integration_id: id, provider_calendar_id: calendar_id})
       when is_integer(id) and is_binary(calendar_id),
       do: CalendarDirectory.key(id, calendar_id)

  defp calendar_key(_event), do: nil

  # The booker (or a group meeting's participants) plus the invited guests,
  # as the preview lists them.
  defp guest_count(%{kind: :booking} = booking),
    do: booking |> GuestReplies.of_event() |> length()

  defp guest_count(event) do
    event
    |> Map.get(:attendees)
    |> List.wrap()
    |> Enum.count(&(Attendee.normalise(&1).email not in [nil, ""]))
  end

  # How the guests of a booking, or of an event Tymeslot made, have
  # answered (`GuestReplies.summary/1`, with its words for the badge's
  # accessible name); nil when nobody has a reply to show. Other events'
  # attendees are someone else's to chase.
  defp replies(%{kind: :booking} = booking), do: summarise(booking)
  defp replies(%{created_by_tymeslot: true} = event), do: summarise(event)
  defp replies(_event), do: nil

  defp summarise(event) do
    case event |> GuestReplies.of_event() |> GuestReplies.summary() do
      nil -> nil
      summary -> Map.put(summary, :label, GuestReplies.summary_text(summary))
    end
  end

  defp draft_timing(%CreateParams{all_day: true} = params, timezone),
    do: timing(%{all_day: true, start_date: params.start_at, end_date: params.end_at}, timezone)

  defp draft_timing(%CreateParams{} = params, timezone),
    do: timing(%{start_at: params.start_at, end_at: params.end_at}, timezone)

  defp editable?(event, context),
    do:
      EditGuard.drawn_writable(Map.get(context, :integrations, []), locked_uids(context), event) ==
        :ok

  defp locked_uids(context), do: Map.get(context, :locked_uids) || MapSet.new()

  defp movable?(event, %{movable_ids: ids}), do: MapSet.member?(ids, id(event))

  defp movable?(event, context),
    do: EditGuard.movable?(Map.get(context, :integrations, []), event)

  defp untitled, do: dgettext("dashboard_calendar", "(No title)")

  defp kind(%{kind: :booking}), do: "booking"
  defp kind(_event), do: "event"

  defp timing(%{all_day: true, start_date: %Date{} = first} = event, _timezone),
    do: %{
      all_day: true,
      start: Date.to_iso8601(first),
      end: Date.to_iso8601(exclusive_end(event))
    }

  defp timing(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at}, timezone) do
    start = local(start_at, timezone)
    finish = local(end_at, timezone)

    # When the clocks go back the hour repeats, so an event inside it can end
    # on the wall clock before it starts, and one shorter than a minute ends
    # in the minute it starts. Either would draw as no block at all; keep its
    # real length from the wall-clock start instead.
    finish =
      if NaiveDateTime.compare(finish, start) == :gt,
        do: finish,
        else: NaiveDateTime.add(start, max(ceil_minutes(start_at, end_at), 1), :minute)

    %{all_day: false, start: format(start), end: format(finish)}
  end

  defp local(datetime, timezone) do
    shifted =
      case DateTime.shift_zone(datetime, timezone) do
        {:ok, shifted} -> shifted
        {:error, _reason} -> datetime
      end

    shifted |> DateTime.to_naive() |> NaiveDateTime.truncate(:second) |> Map.put(:second, 0)
  end

  defp ceil_minutes(start_at, end_at),
    do: div(DateTime.diff(end_at, start_at, :second) + 59, 60)

  defp format(naive), do: Calendar.strftime(naive, "%Y-%m-%dT%H:%M")
end
