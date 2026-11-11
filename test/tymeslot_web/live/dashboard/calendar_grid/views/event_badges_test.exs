defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.EventBadgesTest do
  @moduledoc """
  The guest and seat-lock badges on a timed event block.

  The block is the control keyboard and screen-reader users reach, and its
  `aria-label` replaces whatever the badges inside it say, so the block's own
  name has to carry their information. On touch, a tap on a badge must show
  its tooltip without also opening the event, which the badge's anchor asks of
  the tooltip script with `data-tooltip-isolated`.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.Integrations.Calendar.EventColour
  alias TymeslotWeb.Dashboard.CalendarGrid.GridViews

  @monday ~D[2026-04-13]
  @visible_days Enum.map(0..6, &Date.add(@monday, &1))
  @locked_message "This is a group booking. Move it, cancel it or change who attends from the meeting instead."

  defp event do
    %{
      id: 7,
      uid: "meeting-uid-7",
      summary: "Workshop",
      all_day: false,
      start_date: nil,
      end_date: nil,
      start_at: ~U[2026-04-15 10:00:00Z],
      end_at: ~U[2026-04-15 11:00:00Z],
      calendar_integration_id: 1,
      colour: nil,
      created_by_tymeslot: true
    }
  end

  defp render_week(overrides) do
    assigns =
      Map.merge(
        %{
          view: :week,
          visible_days: @visible_days,
          visible_events: [event()],
          events: [event()],
          integrations: [],
          integration_colors: %{1 => EventColour.rotation_class(1)},
          calendar_colors: %{},
          hidden_integration_ids: [],
          current_time: ~U[2026-04-15 08:00:00Z],
          user_timezone: "Etc/UTC",
          preferences: nil,
          stale_integrations: [],
          oldest_sync_at: nil,
          syncing: false,
          sync_total: 0,
          sync_completed: 0,
          date: ~D[2026-04-15],
          guest_rsvp_summaries: %{},
          group_booking_uids: MapSet.new(),
          myself: nil
        },
        overrides
      )

    render_component(&GridViews.week_day_view/1, assigns)
  end

  defp block_label(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#event-7-2026-04-15")
    |> LazyHTML.attribute("aria-label")
    |> List.first()
  end

  defp isolated_anchors(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#event-7-2026-04-15 [data-tooltip][data-tooltip-isolated]")
    |> Enum.count()
  end

  test "an event with guests names the guest count in its accessible name" do
    summary = %{total: 3, accepted: 1, declined: 1, pending: 1}
    html = render_week(%{guest_rsvp_summaries: %{"meeting-uid-7" => summary}})

    assert block_label(html) =~ "Workshop, "
    assert block_label(html) =~ "1 of 3 guests going, 1 declined"
    assert isolated_anchors(html) == 1
  end

  test "a seat-locked event names the lock in its accessible name" do
    html = render_week(%{group_booking_uids: MapSet.new(["meeting-uid-7"])})

    assert block_label(html) =~ @locked_message
    assert isolated_anchors(html) == 1
  end

  test "an event with no badges keeps its plain name" do
    html = render_week(%{})
    label = block_label(html)

    assert label =~ "Workshop, "
    refute label =~ "guests going"
    refute label =~ "group booking"
    assert isolated_anchors(html) == 0
  end
end
