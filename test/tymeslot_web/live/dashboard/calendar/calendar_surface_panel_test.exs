defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePanelTest do
  @moduledoc """
  The side panel opens beside the grid on `calendar:edit`, closes with its
  button or Escape and hands focus back to the event, takes the preview's
  place, and opens read only, saying why, for an event the organiser cannot
  change.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.Repo

  setup %{conn: conn} do
    context = owner(conn)
    review = event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    Map.merge(context, %{lv: lv, review: review, id: "event-#{review.id}"})
  end

  defp edit(lv, id),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:edit", %{"id" => id})

  defp open_preview(lv, id),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:open", %{"id" => id})

  test "opens beside the grid on the event, its title marked for focus", %{lv: lv, id: id} do
    edit(lv, id)

    assert has_element?(lv, "#calendar-canvas + #calendar-panel")
    assert has_element?(lv, "#calendar-panel-title[value='Design review'][data-panel-focus]")
    assert has_element?(lv, "#calendar-panel-status[role='status']", "Changes save automatically")
    assert_push_event(lv, "calendar:panel", %{open: true})
  end

  test "the close button closes it and hands focus back to the event", %{lv: lv, id: id} do
    edit(lv, id)
    lv |> element("#calendar-panel-close") |> render_click()

    refute has_element?(lv, "#calendar-panel")
    assert_push_event(lv, "calendar:panel", %{open: false, focus: ^id})
  end

  test "the hook's panel:close (Escape inside the panel) closes it", %{lv: lv, id: id} do
    edit(lv, id)
    lv |> element("#calendar-canvas") |> render_hook("panel:close", %{})

    refute has_element?(lv, "#calendar-panel")
    assert_push_event(lv, "calendar:panel", %{open: false, focus: ^id})
  end

  test "opening the panel closes the preview, and opening the preview closes the panel", %{
    lv: lv,
    id: id
  } do
    open_preview(lv, id)
    assert has_element?(lv, "#calendar-preview")

    edit(lv, id)
    refute has_element?(lv, "#calendar-preview")
    assert has_element?(lv, "#calendar-panel")

    open_preview(lv, id)
    assert has_element?(lv, "#calendar-preview")
    refute has_element?(lv, "#calendar-panel")
  end

  test "an id that is not a loaded event opens nothing", %{lv: lv} do
    edit(lv, "event-0")

    refute has_element?(lv, "#calendar-panel")
  end

  test "a panel event with no panel open changes nothing", %{lv: lv} do
    lv |> element("#calendar-canvas") |> render_hook("panel:close", %{})

    refute has_element?(lv, "#calendar-panel")
  end

  test "a booking opens read only and says where to change it", %{conn: conn, user: user} do
    meeting =
      insert(:meeting,
        organizer_user: user,
        title: "Intro call",
        attendee_name: "Anna Kowalski",
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 10:30:00Z],
        status: "confirmed"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    edit(lv, "booking-#{meeting.id}")

    assert has_element?(lv, "#calendar-panel-status", "Read only")

    assert has_element?(
             lv,
             "#calendar-panel-read-only",
             "This is a booking. Reschedule or cancel it from Bookings."
           )

    assert has_element?(lv, "#calendar-panel-title[disabled]")
    assert has_element?(lv, "#calendar-panel-close[data-panel-focus]")
  end

  test "an event on a read-only calendar opens read only", %{
    conn: conn,
    integration: integration
  } do
    integration
    |> Changeset.change(
      calendar_list: [
        %{"id" => "work", "name" => "Work", "selected" => true},
        %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
      ]
    )
    |> Repo.update!()

    shared = event(integration, "shared", "Team offsite", ~U[2026-10-16 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    edit(lv, "event-#{shared.id}")

    assert has_element?(lv, "#calendar-panel-status", "Read only")
    assert has_element?(lv, "#calendar-panel-read-only", "This calendar is read-only.")
    assert has_element?(lv, "#calendar-panel-title[disabled]")
  end
end
