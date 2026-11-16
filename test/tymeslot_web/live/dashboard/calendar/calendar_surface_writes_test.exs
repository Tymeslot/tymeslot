defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceWritesTest do
  @moduledoc """
  The calendar drives the write queue: write results reach it through
  `CalendarRouting` only while it is on screen, and a surface LiveView
  revives after the organiser left (rather than mounts afresh) takes the
  queue back from its guardian exactly once.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers, only: [owner: 1, event: 4]
  import Phoenix.LiveView, only: [send_update: 3]

  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.CalendarGrid.WriteQueue
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.CalendarEventHandlers

  describe "routing a write's answer" do
    test "reaches the calendar on the calendar page" do
      socket = %{assigns: %{live_action: :calendar}}

      CalendarEventHandlers.handle_event_update_result(
        {:ok, write: {"uid", 1}, updated_event: %{id: "e"}},
        socket
      )

      assert_received {:phoenix, :send_update,
                       {{CalendarSurface, "calendar"},
                        %{action: :event_write_settled, write: {"uid", 1}}}}
    end

    test "is not sent off the calendar page" do
      socket = %{assigns: %{live_action: :overview}}

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

  describe "what a write's answer pushes" do
    setup %{conn: conn} do
      context = owner(conn)
      {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")
      render(lv)
      flush_pushes(lv)
      Map.put(context, :lv, lv)
    end

    test "nothing when the answer is for a write that is not in flight", %{lv: lv} do
      send_update(lv.pid, CalendarSurface,
        id: "calendar",
        action: :event_write_settled,
        write: {{1, "gone"}, 1},
        outcome: {:ok, %{}}
      )

      render(lv)
      refute_push_event(lv, "calendar:events", %{}, 100)
    end

    test "nothing when a release is for an event the surface is not waiting for", %{lv: lv} do
      send_update(lv.pid, CalendarSurface,
        id: "calendar",
        action: :event_writes_released,
        release: {self(), {1, "gone"}, :unknown}
      )

      render(lv)
      refute_push_event(lv, "calendar:events", %{}, 100)
    end

    test "a series-wide change reaching the surface resets the hook's cache", %{
      lv: lv,
      user: user,
      integration: integration
    } do
      review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])

      # Another LiveView of the organiser is writing the event.
      {queue, _effects} = WriteQueue.update(WriteQueue.new(), review, %{}, [], nil)
      :ok = WriteGuardian.mirror(queue, user.id)
      [{lender, _value}] = Registry.lookup(WriteGuardian.registry(), self())

      # The surface is revived and waits for it.
      update_surface(lv, calendar_left: 1)
      flush_pushes(lv)

      send_update(lv.pid, CalendarSurface,
        id: "calendar",
        action: :event_writes_released,
        release: {lender, WriteQueue.key(review), :series_changed}
      )

      render(lv)
      assert_push_event(lv, "calendar:events", %{reset: true}, 500)
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
