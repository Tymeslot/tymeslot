defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSeatLockTest do
  @moduledoc """
  An event a group meeting with live seats sits on, on the calendar: the
  grid gets it neither editable nor movable and marked locked, the preview
  says why and offers no change, the side panel opens read only with the
  same reason, and a move sent anyway is still refused.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar

  @lock "This is a group booking. Move it, cancel it or change who attends from the meeting instead."

  setup %{conn: conn} do
    context = owner(conn)

    # The host moved the meeting's calendar event into this week in their own
    # calendar; the meeting itself is next month, so the grid draws the event.
    meeting =
      insert(:meeting,
        organizer_user: context.user,
        organizer_user_id: context.user.id,
        capacity: 3,
        start_time: ~U[2026-11-18 13:00:00Z],
        end_time: ~U[2026-11-18 14:00:00Z]
      )

    insert(:participant, meeting: meeting)

    session =
      event(context.integration, "work", "Yoga class", ~U[2026-10-14 13:00:00Z], 60,
        uid: meeting.calendar_uid
      )

    plain = event(context.integration, "work", "Design review", ~U[2026-10-15 09:00:00Z])

    Map.merge(context, %{meeting: meeting, session: session, plain: plain})
  end

  defp hook(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  # The window the hook draws first, as `calendar:ready` answers it.
  defp loaded(lv, id) do
    hook(lv, "calendar:ready", %{})
    assert_reply(lv, %{events: events})
    Enum.find(events, &(&1.id == id))
  end

  defp pushed(lv, id) do
    assert_push_event(lv, "calendar:events", %{events: events})
    Enum.find(events, &(&1.id == id))
  end

  test "the grid gets the event locked, neither editable nor movable", %{
    conn: conn,
    session: session,
    plain: plain
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert %{locked: true, editable: false, movable: false} =
             loaded(lv, "event-#{session.id}")

    assert %{locked: false, editable: true, movable: true} = loaded(lv, "event-#{plain.id}")
  end

  test "the preview says why and offers no Edit or Delete", %{conn: conn, session: session} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:open", %{"id" => "event-#{session.id}"})

    assert has_element?(lv, "#calendar-preview-locked", @lock)
    refute has_element?(lv, "#calendar-preview-edit")
    refute has_element?(lv, "#calendar-preview-delete")
    refute has_element?(lv, "#calendar-preview-free")
  end

  test "an unlocked event's preview has no lock note", %{conn: conn, plain: plain} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:open", %{"id" => "event-#{plain.id}"})

    refute has_element?(lv, "#calendar-preview-locked")
    assert has_element?(lv, "#calendar-preview-edit")
  end

  test "the side panel opens read only, saying why, with its timing disabled", %{
    conn: conn,
    session: session
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:edit", %{"id" => "event-#{session.id}"})

    assert has_element?(lv, "#calendar-panel-read-only", @lock)
    assert has_element?(lv, "#calendar-panel-title[disabled]")
    assert has_element?(lv, "#calendar-panel-timing fieldset[disabled]")
  end

  test "the side panel offers no colour, and a colour sent anyway is refused", %{
    conn: conn,
    user: user,
    session: session
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:edit", %{"id" => "event-#{session.id}"})

    refute has_element?(lv, "#calendar-panel-colour")

    hook(lv, "panel:colour", %{"colour" => "tomato"})

    assert Calendar.overrides_for(user.id) == %{}
  end

  test "a move sent anyway is refused and the event stays", %{conn: conn, session: session} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    id = "event-#{session.id}"

    hook(lv, "calendar:move", %{
      "id" => id,
      "start" => "2026-10-15T11:00",
      "end" => "2026-10-15T12:00"
    })

    assert %{start: "2026-10-14T14:00", locked: true} = pushed(lv, id)
  end

  test "a group booking on the grid is drawn locked, and its preview says so", %{
    conn: conn,
    user: user
  } do
    group =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        capacity: 4,
        start_time: ~U[2026-10-16 10:00:00Z],
        end_time: ~U[2026-10-16 11:00:00Z]
      )

    insert(:participant, meeting: group)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    assert %{locked: true, movable: false} = loaded(lv, "booking-#{group.id}")

    hook(lv, "calendar:open", %{"id" => "booking-#{group.id}"})
    assert has_element?(lv, "#calendar-preview-locked", @lock)
  end
end
