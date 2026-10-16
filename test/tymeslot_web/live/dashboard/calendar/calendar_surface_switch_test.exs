defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSwitchTest do
  @moduledoc """
  The per-user switch between the old calendar and the redesigned one: a
  "Try the new calendar" control in the old calendar's settings, a "Back to
  the old calendar" control in the new one's display options, and the choice
  remembered across visits.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarGridWriteHelpers,
    only: [answer: 2, edit: 3, hold_writes: 1, open_event: 2, settled: 1, standup: 3]

  import TymeslotWeb.CalendarSurfaceHelpers, only: [owner: 1, owner: 2]

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.CalendarEventHandlers

  @write_timeout 5_000

  describe "from the old calendar" do
    setup %{conn: conn}, do: owner(conn, redesign_enabled: false)

    test "an organiser who never switched keeps the old grid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-grid")
      refute has_element?(lv, "#calendar-surface")
    end

    test "Try the new calendar swaps the surface and remembers the choice", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("button[phx-click='toggle_settings']") |> render_click()
      lv |> element("#calendar-try-new") |> render_click()

      assert has_element?(lv, "#calendar-surface")
      refute has_element?(lv, "#calendar-grid")
      assert CalendarPreferencesQueries.get_or_create(user.id).redesign_enabled
    end
  end

  describe "from the new calendar" do
    setup %{conn: conn}, do: owner(conn)

    test "Back to the old calendar swaps back, and the next visit opens the old grid", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-display-options > button") |> render_click()
      lv |> element("#calendar-back-to-old") |> render_click()

      assert has_element?(lv, "#calendar-grid")
      refute CalendarPreferencesQueries.get_or_create(user.id).redesign_enabled

      {:ok, again, _html} = live(conn, ~p"/dashboard/calendar")
      assert has_element?(again, "#calendar-grid")
    end
  end

  # Swapping surfaces unmounts the old grid while the LiveView lives on, as
  # leaving the calendar does: the write guardian drives the queue, and the
  # old grid, which LiveView deletes only once the browser confirms its
  # removal, must not start the next write as well.
  describe "writes queued on the old grid" do
    setup :hold_writes

    setup %{integration: integration} do
      {:ok, event: standup(integration, "Team Standup", "Room 101")}
    end

    test "start once, from the guardian, after a switch to the new calendar", %{
      conn: conn,
      event: event
    } do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "First title")
      edit(lv, "update_event_location", "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      switch = queue_switch(lv)
      answer(first, :ok)
      :ok = :sys.resume(lv.pid)
      Task.await(switch)
      assert has_element?(lv, "#calendar-surface")

      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, @write_timeout
      refute_receive {:write_started, _pid, _uid, _payload}, 200
      answer(second, :ok)
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    test "a new edit after switching back waits behind the one still saving", %{
      conn: conn,
      event: event
    } do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "First title")
      edit(lv, "update_event_location", "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      switch_surface(lv, true)
      answer(first, :ok)
      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, @write_timeout

      switch_surface(lv, false)
      lv |> element("[id^='event-#{event.id}-']") |> render_click()
      edit(lv, "update_event_title", "Third title")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(second, :ok)

      assert_receive {:write_started, third, _uid, payload}, @write_timeout
      assert %{summary: "Third title", location: "Room 9"} = payload
      answer(third, :ok)

      assert settled(lv) =~ "Third title"
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end
  end

  describe "the old grid's messages while the new calendar is shown" do
    test "none are sent to it" do
      new_surface = %{assigns: %{live_action: :calendar, calendar_redesign: true}}

      CalendarEventHandlers.handle_tick(new_surface)
      CalendarEventHandlers.handle_event_writes_released({1, "uid"}, new_surface)
      CalendarEventHandlers.handle_event_update_result({:ok, write: nil}, new_surface)

      refute_received {:phoenix, :send_update, _update}
      refute_received :tick
    end

    test "refreshes go to the new surface and to nothing else" do
      new_surface = %{assigns: %{live_action: :calendar, calendar_redesign: true}}

      CalendarEventHandlers.handle_calendar_events_updated(new_surface)
      CalendarEventHandlers.handle_calendar_sync_complete(new_surface)
      CalendarEventHandlers.handle_reset_calendar_sync(new_surface)

      for action <- [:events_updated, :integration_synced, :refresh_events] do
        assert_received {:phoenix, :send_update,
                         {{CalendarSurface, "calendar"}, %{action: ^action}}}
      end

      refute_received {:phoenix, :send_update, _update}
    end

    test "refreshes are not sent to the new surface off the calendar page" do
      elsewhere = %{assigns: %{live_action: :overview, calendar_redesign: true}}

      CalendarEventHandlers.handle_calendar_events_updated(elsewhere)

      refute_received {:phoenix, :send_update, _update}
    end

    test "they are sent to it on the old grid" do
      old_surface = %{assigns: %{live_action: :calendar, calendar_redesign: false}}

      CalendarEventHandlers.handle_calendar_events_updated(old_surface)

      assert_received {:phoenix, :send_update, _update}
    end
  end

  describe "a switch payload that is not a boolean" do
    setup %{conn: conn}, do: owner(conn, redesign_enabled: false)

    test "changes nothing", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      render_hook(lv, "calendar:switch_surface", %{"enabled" => "yes"})

      assert has_element?(lv, "#calendar-grid")
      refute CalendarPreferencesQueries.get_or_create(user.id).redesign_enabled
    end
  end

  # Starts the switch to the new calendar and holds the LiveView suspended
  # with the switch queued: the answer sent meanwhile lands behind it and
  # ahead of the browser's notice that the old grid is gone, so it is handled
  # while the old grid component still lives on the server, as it does for a
  # moment in a browser. Returns once the switch is queued; the caller
  # resumes the LiveView.
  defp queue_switch(lv) do
    :ok = :sys.suspend(lv.pid)
    task = Task.async(fn -> switch_surface(lv, true) end)
    # The client pings the LiveView before it sends the event.
    await_message(lv.pid, &match?({:"$gen_call", _from, {:phoenix, :ping}}, &1))
    :ok = :sys.resume(lv.pid)
    :ok = :sys.suspend(lv.pid)
    await_message(lv.pid, &match?(%Phoenix.Socket.Message{event: "event"}, &1))
    task
  end

  defp await_message(pid, match?, tries \\ 100) do
    {:messages, messages} = Process.info(pid, :messages)

    cond do
      Enum.any?(messages, match?) -> :ok
      tries == 0 -> flunk("#{inspect(pid)} never received the message: #{inspect(messages)}")
      true -> receive(after: (10 -> await_message(pid, match?, tries - 1)))
    end
  end

  defp switch_surface(lv, enabled),
    do: render_hook(lv, "calendar:switch_surface", %{"enabled" => enabled})
end
