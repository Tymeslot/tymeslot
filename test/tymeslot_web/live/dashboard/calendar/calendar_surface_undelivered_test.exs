defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceUndeliveredTest do
  @moduledoc """
  The notice in an event's preview naming the guests its latest update
  email could not reach, and its Dismiss.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarGrid.UndeliveredUpdates

  setup %{conn: conn} do
    context = owner(conn)

    planning =
      event(context.integration, "work", "Planning", ~U[2026-10-14 13:00:00Z], 60,
        attendees: [
          %{"email" => "missed@example.com", "display_name" => "Missed"},
          %{"email" => "reached@example.com", "display_name" => "Reached"}
        ]
      )

    {:ok, Map.put(context, :planning, planning)}
  end

  defp open(lv, event),
    do:
      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:open", %{"id" => "event-#{event.id}"})

  test "names the guests the latest update could not reach, and Dismiss clears them", %{
    conn: conn,
    user: user,
    integration: integration,
    planning: planning
  } do
    UndeliveredUpdates.note_delivery(
      integration.id,
      planning.uid,
      "missed@example.com",
      {:error, :smtp_down}
    )

    UndeliveredUpdates.note_delivery(
      integration.id,
      planning.uid,
      "reached@example.com",
      {:ok, "sent"}
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, planning)

    notice = lv |> element("#calendar-preview-undelivered") |> render()
    assert notice =~ "could not be emailed to this guest"
    assert notice =~ "missed@example.com"
    refute notice =~ "reached@example.com"

    lv |> element("#calendar-preview-undelivered button", "Dismiss") |> render_click()

    refute has_element?(lv, "#calendar-preview-undelivered")
    assert has_element?(lv, "#calendar-preview")
    assert UndeliveredUpdates.list_for_event(user.id, integration.id, planning.uid) == []
  end

  test "shows no notice for an event whose update reached everyone", %{
    conn: conn,
    planning: planning
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, planning)

    assert has_element?(lv, "#calendar-preview")
    refute has_element?(lv, "#calendar-preview-undelivered")
  end
end
