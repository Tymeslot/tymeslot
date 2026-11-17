defmodule TymeslotWeb.Dashboard.CalendarMessagesTest do
  @moduledoc """
  `DashboardLive` hands its calendar messages to `CalendarMessages`, which
  routes each to the calendar on screen and answers `:unhandled` for any
  other message, which the LiveView then ignores.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers, only: [owner: 1]

  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.CalendarMessages

  @new_surface %{assigns: %{live_action: :calendar}}

  describe "handle_info/2" do
    test "leaves a message it does not handle to the LiveView" do
      for message <- [
            :tick,
            :calendar_sync_flash,
            :reset_calendar_sync,
            {:create_event_result, {:ok, %{}}},
            {:delete_event_result, {:ok, %{}}},
            {:execute_delete_event, %{}}
          ] do
        assert CalendarMessages.handle_info(message, @new_surface) == :unhandled
      end

      refute_received {:phoenix, :send_update, _update}
    end

    test "a create's result goes to the calendar with its draft" do
      result = {:error, %{reason: :timeout, retry: :not_queued}}

      assert CalendarMessages.handle_info(
               {:calendar_create_result, {"d3", "Lunch"}, result},
               @new_surface
             ) ==
               {:noreply, @new_surface}

      assert_received {:phoenix, :send_update,
                       {{CalendarSurface, "calendar"},
                        %{action: :create_settled, draft: "d3", title: "Lunch", result: ^result}}}
    end

    test "a delete scheduled in another tab still reaches the calendar" do
      message = {:calendar_delete_scheduled, 1, 7, %{id: "event-1"}, :single}

      assert CalendarMessages.handle_info(message, @new_surface) == {:noreply, @new_surface}

      assert_received {:phoenix, :send_update,
                       {{CalendarSurface, "calendar"},
                        %{action: :delete_scheduled, token: 7, scope: :single}}}
    end

    test "a guest's RSVP goes to the calendar on screen" do
      assert CalendarMessages.handle_info({:guest_rsvp_updated, "m1"}, @new_surface) ==
               {:noreply, @new_surface}

      assert_received {:phoenix, :send_update,
                       {{CalendarSurface, "calendar"}, %{action: :refresh_guest_summaries}}}
    end

    test "a message that is not the calendar's is left to the LiveView" do
      assert CalendarMessages.handle_info({:poll_updated, 1}, @new_surface) == :unhandled
      refute_received {:phoenix, :send_update, _update}
    end
  end

  describe "in the dashboard" do
    test "a create's result and a stray message leave the calendar running", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:calendar_create_result, {"d1", "Lunch"}, {:error, %{reason: :timeout}}})
      send(lv.pid, :not_a_calendar_message)

      assert render(lv) =~ "calendar-surface"
      assert Process.alive?(lv.pid)
    end
  end
end
