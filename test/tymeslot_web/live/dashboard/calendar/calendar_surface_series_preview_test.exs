defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSeriesPreviewTest do
  @moduledoc """
  A series the calendar has just written shows its later weeks before any
  sync has cached them, previewed from the series' own row. A preview is
  drawn waiting to sync; opening it opens the series, and a change to it
  alone (a move, a resize, a delete) is refused, saying the calendar is
  syncing.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventDeleteWorker

  setup %{conn: conn} = context do
    context = Map.merge(context, owner(conn))

    # A week before the one the calendar opens on, so only its preview is in
    # view: Wednesdays at 10:00 in London.
    series =
      event(context.integration, "work", "Weekly review", ~U[2026-10-07 09:00:00.000000Z], 60,
        uid: "weekly-ical-uid",
        provider_event_id: "master-1",
        recurrence_rule: "FREQ=WEEKLY;COUNT=4",
        timezone: "Europe/London"
      )

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    Map.merge(context, %{lv: lv, series: series})
  end

  defp canvas(lv, name, params),
    do: lv |> element("#calendar-canvas") |> render_hook(name, params)

  defp preview_id(%{series: series}), do: "preview-#{series.id}-20261014T100000"

  test "draws the next week's occurrence as a preview waiting to sync", context do
    id = preview_id(context)
    canvas(context.lv, "calendar:open", %{"id" => id})

    assert has_element?(context.lv, "#calendar-preview", "Weekly review")
  end

  test "the preview's popover offers Edit, which opens the series, and no Delete", context do
    canvas(context.lv, "calendar:open", %{"id" => preview_id(context)})

    assert has_element?(context.lv, "#calendar-preview", "Syncing with your calendar")
    refute has_element?(context.lv, "#calendar-preview-delete")

    context.lv |> element("#calendar-preview-edit") |> render_click()

    assert has_element?(context.lv, "#calendar-panel input[value='Weekly review']")
    refute has_element?(context.lv, "#calendar-preview")
  end

  test "opening the preview in the panel opens the series", context do
    canvas(context.lv, "calendar:edit", %{"id" => preview_id(context)})

    assert has_element?(context.lv, "#calendar-panel")
    assert has_element?(context.lv, "#calendar-panel input[value='Weekly review']")
  end

  test "deleting the preview alone is refused while the calendar syncs", context do
    canvas(context.lv, "calendar:delete", %{"id" => preview_id(context)})

    assert render(context.lv) =~ "Syncing with your calendar"
    refute_enqueued(worker: CalendarEventDeleteWorker)
  end

  test "showing the preview alone as free is refused while the calendar syncs", context do
    canvas(context.lv, "calendar:set_free", %{"id" => preview_id(context), "free" => "true"})

    assert render(context.lv) =~ "Syncing with your calendar"
    assert Repo.reload!(context.series).transparency == "opaque"
  end

  # A preview is drawn unmovable; a move sent all the same is refused.
  test "moving the preview alone is refused while the calendar syncs, and it stays put",
       context do
    id = preview_id(context)

    canvas(context.lv, "calendar:move", %{
      "id" => id,
      "start" => "2026-10-14T11:00",
      "end" => "2026-10-14T12:00"
    })

    assert render(context.lv) =~ "Syncing with your calendar"
    assert_push_event(context.lv, "calendar:events", %{events: events})

    assert [%{preview: true, attention: true, movable: false, start: "2026-10-14T10:00"}] =
             Enum.filter(events, &(&1.id == id))
  end

  describe "a series cached weeks before the visible ones" do
    # Wednesdays at 10:00 in London from 30 September, two weeks before the
    # week the calendar opens on, so neither the series nor the week after it
    # is loaded.
    setup %{integration: integration, conn: conn} do
      forward_creates(self(), :create)

      series =
        event(integration, "work", "Standup", ~U[2026-09-30 09:00:00.000000Z], 30,
          uid: "standup-ical-uid",
          provider_event_id: "master-2",
          recurrence_rule: "FREQ=WEEKLY;COUNT=6",
          timezone: "Europe/London"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas(lv, "calendar:edit", %{"id" => "preview-#{series.id}-20261014T100000"})
      assert has_element?(lv, "#calendar-panel input[value='Standup']")

      %{far_lv: lv, far_series: series}
    end

    test "the series panel's Delete deletes the whole series", %{far_lv: lv} do
      lv |> element("#calendar-panel-delete") |> render_click()
      lv |> element("#calendar-scope-series") |> render_click()

      assert_enqueued(
        worker: CalendarEventDeleteWorker,
        args: %{"uid" => "standup-ical-uid", "scope" => "series"}
      )
    end

    test "the series panel's Duplicate makes a copy", %{far_lv: lv} do
      lv |> element("#calendar-panel-duplicate") |> render_click()

      assert_receive {:provider_call, _task, {:create, %{summary: "Standup"}}}, 5_000
    end

    test "the series panel offers to move it to another calendar", %{
      far_lv: lv,
      integration: integration
    } do
      lv
      |> form("#calendar-panel-calendar-form")
      |> render_change(%{"calendar" => "#{integration.id}:family"})

      assert has_element?(lv, "#calendar-series-move-confirm")
    end
  end
end
