defmodule Tymeslot.CalendarGrid.EventPayload do
  @moduledoc """
  The JSON the redesigned calendar's `CalendarCanvas` hook draws the grid from.

  Times are wall-clock strings in the organiser's zone (`"2026-10-16T09:30"`),
  never instants: the browser may sit in another zone, and the grid must show
  the organiser's day exactly as the booking engine reads it. All-day events
  carry dates, with the exclusive end they are stored with. Whether an event
  is past is left to the browser, which knows the minute it draws in.

  Event ids are prefixed by kind (`"event-42"`, `"booking-<uuid>"`), so a
  provider row and a booking can never collide in the hook's cache.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.ColourTokens

  @type context :: %{
          required(:timezone) => String.t(),
          required(:integration_tokens) => map(),
          required(:calendar_tokens) => map(),
          optional(atom()) => term()
        }

  @doc """
  The whole payload: the period, the loaded range (`to` exclusive), the
  organiser's current wall-clock minute, the display settings, whether the
  hook should drop everything it holds first (`reset`), and the events.
  """
  @spec build(map()) :: map()
  def build(%{view: view, date: date, window: window, now: now, timezone: timezone} = input) do
    %{
      view: Atom.to_string(view),
      date: Date.to_iso8601(date),
      range: %{from: Date.to_iso8601(window.first), to: Date.to_iso8601(Date.add(window.last, 1))},
      now: format(local(now, timezone)),
      reset: input.reset,
      settings: input.settings,
      events: Enum.map(input.events, &event(&1, input))
    }
  end

  @doc "One event in the payload's shape."
  @spec event(map(), context()) :: map()
  def event(event, context) do
    Map.merge(
      %{
        id: id(event),
        kind: kind(event),
        title: title(event),
        colour:
          ColourTokens.for_event(event, context.integration_tokens, context.calendar_tokens),
        free: Map.get(event, :transparency) == "transparent",
        attention: Map.get(event, :sync_state, "synced") != "synced"
      },
      timing(event, context.timezone)
    )
  end

  @doc "The id the hook knows an event by."
  @spec id(map()) :: String.t()
  def id(%{kind: :booking, id: id}), do: id
  def id(%{id: id}), do: "event-#{id}"

  @doc "The title the grid and the preview show; a booking leads with its guest."
  @spec title(map()) :: String.t()
  def title(%{kind: :booking, attendee_name: name, participants: [], summary: summary})
      when is_binary(name) and name != "",
      do: "#{name} · #{summary}"

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
