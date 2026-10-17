defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceWritesTest do
  @moduledoc """
  The new calendar drives the write queue: write results reach it through
  `CalendarRouting` only while it is on screen, and a surface LiveView
  revives after the organiser left (rather than mounts afresh) takes the
  queue back from its guardian exactly once.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers, only: [owner: 1]
  import Phoenix.LiveView, only: [send_update: 3]

  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.CalendarEventHandlers

  describe "routing a write's answer" do
    test "reaches the new surface on the calendar page" do
      socket = %{assigns: %{live_action: :calendar, calendar_redesign: true}}

      CalendarEventHandlers.handle_event_update_result(
        {:ok, write: {"uid", 1}, updated_event: %{id: "e"}},
        socket
      )

      assert_received {:phoenix, :send_update,
                       {{CalendarSurface, "calendar"},
                        %{action: :event_write_settled, write: {"uid", 1}}}}
    end

    test "is not sent off the calendar page" do
      socket = %{assigns: %{live_action: :overview, calendar_redesign: true}}

      CalendarEventHandlers.handle_event_update_result(
        {:ok, write: {"uid", 1}, updated_event: %{id: "e"}},
        socket
      )

      refute_received {:phoenix, :send_update, _update}
    end
  end

  describe "a surface LiveView revives" do
    setup %{conn: conn}, do: owner(conn)

    test "takes the queue back once, and not on every update", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      render(lv)
      flush_pushes(lv)

      # The parent still counts the same departures: nothing to adopt.
      update_surface(lv, calendar_left: 0)
      refute_push_event(lv, "calendar:events", %{}, 100)

      # The organiser left and came back before the browser confirmed the
      # surface's removal: the guardian's queue is adopted and its changes
      # reloaded.
      update_surface(lv, calendar_left: 1)
      assert_push_event(lv, "calendar:events", %{}, 500)

      # Updated again with the same count: adopted already.
      update_surface(lv, calendar_left: 1)
      refute_push_event(lv, "calendar:events", %{}, 100)
    end
  end

  defp update_surface(lv, assigns) do
    send_update(lv.pid, CalendarSurface, [id: "calendar"] ++ assigns)
    render(lv)
    render(lv)
  end

  defp flush_pushes(lv) do
    receive do
      {_ref, {:push_event, _event, _payload}} -> flush_pushes(lv)
    after
      50 -> :ok
    end
  end
end
