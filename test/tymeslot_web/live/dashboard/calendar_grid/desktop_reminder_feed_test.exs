defmodule TymeslotWeb.Dashboard.CalendarGrid.DesktopReminderFeedTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias TymeslotWeb.Dashboard.CalendarGrid.DesktopReminderFeed

  @now ~U[2026-06-24 12:00:00Z]

  defp event(fields) do
    Map.merge(
      %{id: 1, summary: "Event", start_at: nil, location: nil, reminders: []},
      fields
    )
  end

  defp build(events, opts \\ []) do
    timezone = Keyword.get(opts, :timezone, "Europe/Berlin")
    time_format = Keyword.get(opts, :time_format, "12h")
    DesktopReminderFeed.build(events, @now, timezone, time_format)
  end

  test "emits one entry per distinct reminder offset, fired at start - offset" do
    events = [
      event(%{
        id: 7,
        summary: "Standup",
        start_at: ~U[2026-06-24 13:00:00Z],
        location: "Room 1",
        reminders: [%{method: :popup, minutes_before: 10}, %{method: :email, minutes_before: 30}]
      })
    ]

    feed = build(events)

    assert [%{fire_at_ms: earlier}, %{fire_at_ms: later}] = feed
    assert earlier == DateTime.to_unix(~U[2026-06-24 12:30:00Z], :millisecond)
    assert later == DateTime.to_unix(~U[2026-06-24 12:50:00Z], :millisecond)
    # 15:00 Berlin (13:00Z in summer), today, with the location appended.
    assert Enum.all?(feed, &(&1.title == "Reminder: Standup"))
    assert Enum.all?(feed, &(&1.body == "Today at 3:00 PM · Room 1"))
    assert [%{key: "7|" <> _rest}, _second] = feed
  end

  test "collapses duplicate offsets to a single entry" do
    events = [
      event(%{
        start_at: ~U[2026-06-24 13:00:00Z],
        reminders: [%{method: :popup, minutes_before: 10}, %{method: :email, minutes_before: 10}]
      })
    ]

    assert [_only] = build(events)
  end

  test "drops reminders whose fire time is already well in the past" do
    events = [
      event(%{
        start_at: ~U[2026-06-24 12:01:00Z],
        reminders: [%{method: :popup, minutes_before: 30}]
      })
    ]

    # fire = 11:31Z, ~29 min before now → outside the 2-minute grace, dropped.
    assert build(events) == []
  end

  test "skips events without a start instant" do
    events = [event(%{start_at: nil, reminders: [%{method: :popup, minutes_before: 10}]})]
    assert build(events) == []
  end

  test "formats the body for a 24h-clock host and a non-today date" do
    events = [
      event(%{
        start_at: ~U[2026-06-25 08:30:00Z],
        reminders: [%{method: :popup, minutes_before: 10}]
      })
    ]

    # 08:30Z == 10:30 Berlin on the day after `now` → "Tomorrow at 10:30".
    assert [%{body: "Tomorrow at 10:30"}] = build(events, time_format: "24h")
  end
end
