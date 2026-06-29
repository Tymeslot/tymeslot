defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.MonthViewTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.Views.MonthView

  # Month of April 2026, rendered as a 6×7 matrix starting Monday 30 March.
  @visible_days Enum.map(0..41, &Date.add(~D[2026-03-30], &1))

  defp base_assigns(events) do
    %{
      view: :month,
      visible_days: @visible_days,
      visible_events: events,
      integrations: [],
      integration_colors: %{1 => 1},
      hidden_integration_ids: [],
      date: ~D[2026-04-15],
      user_timezone: "Etc/UTC",
      preferences: nil,
      guest_rsvp_summaries: %{},
      myself: nil
    }
  end

  # visible_events are cache-row structs in production; a plain map with the
  # same fields is enough to exercise the layout + render path.
  defp event(fields) do
    Map.merge(
      %{
        id: nil,
        summary: nil,
        all_day: false,
        start_date: nil,
        end_date: nil,
        start_at: nil,
        end_at: nil,
        calendar_integration_id: 1,
        colour: nil,
        created_by_tymeslot: false
      },
      fields
    )
  end

  defp all_day_event(id, summary, start_date, end_date) do
    event(%{id: id, summary: summary, all_day: true, start_date: start_date, end_date: end_date})
  end

  defp timed_event(id, summary, start_at, end_at) do
    event(%{id: id, summary: summary, start_at: start_at, end_at: end_at})
  end

  test "all-day events render in the month grid (regression: they used to be dropped)" do
    events = [all_day_event(1, "Conference", ~D[2026-04-07], ~D[2026-04-10])]

    html = render_component(&MonthView.month_view/1, base_assigns(events))

    assert html =~ "Conference"
    # Rendered as a spanning bar (pointer-events-auto re-enables clicks on the bar).
    assert html =~ "pointer-events-auto"
    assert html =~ ~s(phx-value-event-id="1")
  end

  test "overlapping multi-day events are packed into separate lanes" do
    events = [
      all_day_event(1, "Conference", ~D[2026-04-07], ~D[2026-04-10]),
      timed_event(2, "Travel", ~U[2026-04-07 22:00:00Z], ~U[2026-04-09 02:00:00Z])
    ]

    html = render_component(&MonthView.month_view/1, base_assigns(events))

    assert html =~ "Conference"
    assert html =~ "Travel"
    # Two lanes: the first bar sits at the band top, the second one lane below.
    assert html =~ "top: 1.5rem"
    assert html =~ "top: 2.75rem"
  end

  test "single-day timed events render as chips, not bars" do
    events = [timed_event(3, "Lunch", ~U[2026-04-08 11:00:00Z], ~U[2026-04-08 12:00:00Z])]

    html = render_component(&MonthView.month_view/1, base_assigns(events))

    assert html =~ "Lunch"
    # A lone single-day event needs no bar lane, so no spanning-bar overlay.
    refute html =~ "pointer-events-auto"
  end
end
