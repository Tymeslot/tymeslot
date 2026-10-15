defmodule TymeslotWeb.Dashboard.CalendarGrid.DesktopReminderFeed do
  @moduledoc """
  Builds the desktop-reminder feed handed to the `DesktopReminders` JS hook.

  Each upcoming event contributes one feed entry per distinct reminder offset:

      %{key: String.t(), fire_at_ms: integer(), title: String.t(), body: String.t()}

  * `fire_at_ms` is the absolute fire instant (`start - offset`) as a UTC epoch
    in milliseconds, so the browser only ever compares timestamps — no
    client-side timezone maths.
  * `title`/`body` are pre-formatted in the host's timezone here on the server.
  * `key` is stable per (event, occurrence, offset) so the hook can de-duplicate
    and never fire the same reminder twice.

  Entries whose fire instant is already more than two minutes in the past are
  dropped — the hook only fires reminders crossing its polling window, so stale
  ones would never fire anyway and only bloat the payload.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.Reminder
  alias TymeslotWeb.Dashboard.DashboardFormat

  # Reminders whose fire time is older than this are pruned from the feed.
  @stale_grace_ms 120_000

  @type entry :: %{
          key: String.t(),
          fire_at_ms: integer(),
          title: String.t(),
          body: String.t()
        }

  @doc """
  Turns upcoming reminder-bearing events into hook feed entries.

  `events` is a list of structs/maps exposing `:id`, `:summary`, `:start_at`
  (a `DateTime`), `:location`, and a normalised `:reminders` list. `now` is the
  reference instant, `timezone` the host's IANA zone, and `time_format` either
  `"12h"` or `"24h"`.
  """
  @spec build([map()], DateTime.t(), String.t(), String.t()) :: [entry()]
  def build(events, now, timezone, time_format) do
    now_ms = DateTime.to_unix(now, :millisecond)
    today = DashboardFormat.local_date(now, timezone)

    events
    |> Enum.flat_map(&entries_for_event(&1, today, timezone, time_format))
    |> Enum.uniq_by(& &1.key)
    |> Enum.reject(&(&1.fire_at_ms < now_ms - @stale_grace_ms))
    |> Enum.sort_by(& &1.fire_at_ms)
  end

  defp entries_for_event(
         %{start_at: %DateTime{} = start_at} = event,
         today,
         timezone,
         time_format
       ) do
    title =
      dgettext("dashboard_calendar", "Reminder: %{title}",
        title: DashboardFormat.title(event.summary)
      )

    body = build_body(event, start_at, today, timezone, time_format)

    event.reminders
    |> Enum.map(&Reminder.normalise/1)
    |> Enum.map(& &1.minutes_before)
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.map(fn minutes ->
      fire_at = DateTime.add(start_at, -minutes, :minute)

      %{
        key: "#{event.id}|#{DateTime.to_unix(start_at)}|#{minutes}",
        fire_at_ms: DateTime.to_unix(fire_at, :millisecond),
        title: title,
        body: body
      }
    end)
  end

  defp entries_for_event(_event, _today, _timezone, _time_format), do: []

  defp build_body(event, start_at, today, timezone, time_format) do
    when_label =
      dgettext("dashboard_calendar", "%{day} at %{time}",
        day: DashboardFormat.relative_date(DashboardFormat.local_date(start_at, timezone), today),
        time: DashboardFormat.clock(start_at, timezone, time_format)
      )

    case event.location do
      location when is_binary(location) and location != "" ->
        dgettext("dashboard_calendar", "%{when_text} · %{location}",
          when_text: when_label,
          location: location
        )

      _no_location ->
        when_label
    end
  end
end
