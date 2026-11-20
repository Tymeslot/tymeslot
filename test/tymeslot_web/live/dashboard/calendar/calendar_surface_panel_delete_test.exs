defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePanelDeleteTest do
  @moduledoc """
  Delete in the side panel: the panel stays open while the delete asks a
  question (this event or the series, whether to tell its guests), so
  Cancel returns to it, and closes once the delete is scheduled.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Workers.CalendarEventDeleteWorker

  setup %{conn: conn}, do: owner(conn)

  defp canvas(lv, name, params),
    do: lv |> element("#calendar-canvas") |> render_hook(name, params)

  defp panel_delete(lv, event) do
    canvas(lv, "calendar:edit", %{"id" => "event-#{event.id}"})
    assert has_element?(lv, "#calendar-panel")
    lv |> element("#calendar-panel-delete") |> render_click()
    lv
  end

  defp standup(integration),
    do:
      event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
        recurring_event_id: "standup-series"
      )

  test "Cancel on the series question returns to the panel", %{
    conn: conn,
    integration: integration
  } do
    standup = standup(integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    panel_delete(lv, standup)

    assert has_element?(lv, "#calendar-series-scope")
    assert has_element?(lv, "#calendar-panel")

    lv |> element("#calendar-series-scope button", "Cancel") |> render_click()

    refute has_element?(lv, "#calendar-series-scope")
    assert has_element?(lv, "#calendar-panel")
    refute_enqueued(worker: CalendarEventDeleteWorker)
  end

  test "a second Delete while the series question shows still asks once", %{
    conn: conn,
    integration: integration
  } do
    standup = standup(integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> panel_delete(standup) |> element("#calendar-panel-delete") |> render_click()

    # `element/2` raises if a second dialog put a second button on the page.
    lv |> element("#calendar-scope-occurrence") |> render_click()

    assert [_one] = all_enqueued(worker: CalendarEventDeleteWorker)
  end

  test "choosing a scope deletes the event and closes the panel", %{
    conn: conn,
    integration: integration
  } do
    standup = standup(integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    panel_delete(lv, standup)
    lv |> element("#calendar-scope-occurrence") |> render_click()

    refute has_element?(lv, "#calendar-panel")
    assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"scope" => "occurrence"})
  end

  test "Cancel on the guest question returns to the panel; answering it closes the panel", %{
    conn: conn,
    integration: integration
  } do
    call =
      event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
        attendees: [%{"email" => "ada@example.com"}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    panel_delete(lv, call)

    assert has_element?(lv, "#calendar-delete-confirm")
    assert has_element?(lv, "#calendar-panel")

    lv |> element("#calendar-delete-confirm button", "Cancel") |> render_click()

    refute has_element?(lv, "#calendar-delete-confirm")
    assert has_element?(lv, "#calendar-panel")
    refute_enqueued(worker: CalendarEventDeleteWorker)

    lv |> element("#calendar-panel-delete") |> render_click()
    lv |> element("#calendar-delete-quietly") |> render_click()

    refute has_element?(lv, "#calendar-panel")
    assert_enqueued(worker: CalendarEventDeleteWorker)
  end

  test "an event nobody is told about closes the panel at once", %{
    conn: conn,
    integration: integration
  } do
    dentist = event(integration, "work", "Dentist", ~U[2026-10-15 14:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    panel_delete(lv, dentist)

    refute has_element?(lv, "#calendar-panel")
    assert has_element?(lv, "#calendar-undo")
  end
end
