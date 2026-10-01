defmodule TymeslotWeb.Dashboard.CalendarGrid.EventWriteLendingTest do
  @moduledoc """
  When the grid mounts in a new LiveView while another of the organiser's
  LiveViews still has writes for an event (an old one whose connection
  dropped, or another open tab), the new grid's edits of that event wait
  until the other has finished with it, and then start from the event as
  its writes left it (see "A grid mounted in another LiveView" in
  `Tymeslot.CalendarGrid.WriteGuardian`).

  The calendar mock holds every write until the test releases it, so the
  tests decide when, and how, each write answers.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarGridWriteHelpers

  alias Tymeslot.CalendarGrid.WriteGuardian

  setup :hold_writes

  describe "when the connection drops and the grid mounts in a new LiveView" do
    setup %{integration: integration} do
      {:ok, event: standup(integration, "Team Standup", "Room 101")}
    end

    # The old LiveView's guardian is still writing its queue; the new grid
    # waits for the event until it has finished, so an edit made there runs
    # after the older ones rather than racing them to the calendar.
    test "a new edit of the event waits behind the older ones still saving", %{
      conn: conn,
      event: event
    } do
      old_lv = open_event(conn, event)

      edit(old_lv, "update_event_title", "First title")
      edit(old_lv, "update_event_location", "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      old_guardian = WriteGuardian.whereis(old_lv.pid)
      guardian_ref = Process.monitor(old_guardian)
      kill(old_lv)

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(first, :ok)

      assert_receive {:write_started, second, _uid, payload}, 1_000
      assert %{summary: "First title", location: "Room 9"} = payload
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(second, :ok)

      assert_receive {:write_started, third, _uid, payload}, 1_000
      assert %{summary: "Third title", location: "Room 9"} = payload

      # Its queue written, the old guardian stops.
      assert_receive {:DOWN, ^guardian_ref, :process, ^old_guardian, :normal}, 1_000

      answer(third, :ok)

      assert settled(lv) =~ "Third title"
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    # After a short drop the server often notices the old connection only at
    # the heartbeat timeout, so the old LiveView still lives when the grid
    # mounts again, and goes on writing its queue until it is gone.
    test "an edit made while the old LiveView still lives never lands before its older edits", %{
      conn: conn,
      event: event
    } do
      old_lv = open_event(conn, event)

      edit(old_lv, "update_event_title", "First title")
      edit(old_lv, "update_event_location", "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      kill(old_lv)
      answer(first, :ok)

      assert_receive {:write_started, second, _uid, payload}, 1_000
      assert %{summary: "First title", location: "Room 9"} = payload
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(second, :ok)

      # Made onto the event as the older edits left it.
      assert_receive {:write_started, third, _uid, payload}, 1_000
      assert %{summary: "Third title", location: "Room 9"} = payload
      answer(third, :ok)

      assert settled(lv) =~ "Third title"
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    test "an edit kept by a new grid that is gone before the old one is still made last", %{
      conn: conn,
      event: event
    } do
      old_lv = open_event(conn, event)

      edit(old_lv, "update_event_title", "First title")
      edit(old_lv, "update_event_location", "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")

      # The new grid goes first; the old guardian, which lent it the event,
      # then finishes its own queue.
      kill(lv)
      kill(old_lv)
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(first, :ok)

      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, 1_000
      refute_receive {:write_started, _pid, _uid, _payload}, 200
      answer(second, :ok)

      assert_receive {:write_started, third, _uid, payload}, 1_000
      assert %{summary: "Third title", location: "Room 9"} = payload
      answer(third, :ok)

      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    test "the writes of every LiveView gone are waited for", %{
      conn: conn,
      integration: integration,
      event: event
    } do
      review = standup(integration, "Design Review", "Room 202", ~T[14:00:00])

      tab_one = open_event(conn, event)
      edit(tab_one, "update_event_title", "Standup renamed")
      assert_receive {:write_started, standup_write, _uid, %{summary: "Standup renamed"}}, 1_000

      tab_two = open_event(conn, review)
      edit(tab_two, "update_event_title", "Review renamed")
      assert_receive {:write_started, review_write, _uid, %{summary: "Review renamed"}}, 1_000

      kill(tab_one)
      kill(tab_two)

      lv = open_event(conn, event)
      edit(lv, "update_event_location", "Room 9")
      lv |> element("[id^='event-#{review.id}-']") |> render_click()
      edit(lv, "update_event_location", "Room 8")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(standup_write, :ok)
      assert_receive {:write_started, next, _uid, %{location: "Room 9"}}, 1_000
      answer(next, :ok)

      answer(review_write, :ok)
      assert_receive {:write_started, next, _uid, %{location: "Room 8"}}, 1_000
      answer(next, :ok)

      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    # A guardian killed outright (a brutal kill at the end of its shutdown
    # time) never releases the events it lent; the new grid's guardian
    # notices it is gone and releases them in its place.
    test "an edit kept for an event whose old guardian is killed outright still starts", %{
      conn: conn,
      event: event
    } do
      old_lv = open_event(conn, event)
      edit(old_lv, "update_event_title", "First title")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      old_guardian = WriteGuardian.whereis(old_lv.pid)
      kill(old_lv)

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      Process.exit(old_guardian, :kill)

      # Well within the guardian's drain timeout.
      assert_receive {:write_started, kept, _uid, %{summary: "Third title"}}, 1_000
      answer(kept, :ok)
      answer(first, :ok)

      assert settled(lv) =~ "Third title"
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    test "an edit kept by a grid that is gone starts once the old guardian is killed outright", %{
      conn: conn,
      event: event
    } do
      old_lv = open_event(conn, event)
      edit(old_lv, "update_event_title", "First title")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      old_guardian = WriteGuardian.whereis(old_lv.pid)
      kill(old_lv)

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")

      # The new grid's guardian now drives its queue.
      kill(lv)
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      Process.exit(old_guardian, :kill)

      assert_receive {:write_started, kept, _uid, %{summary: "Third title"}}, 1_000
      answer(kept, :ok)
      answer(first, :ok)

      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    test "an old guardian that released the event and is then killed starts the kept edit once",
         %{
           conn: conn,
           event: event
         } do
      old_lv = open_event(conn, event)
      edit(old_lv, "update_event_title", "First title")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(first, :ok)
      assert settled(old_lv) =~ "First title"
      assert_receive {:write_started, kept, _uid, %{summary: "Third title"}}, 1_000

      old_guardian = WriteGuardian.whereis(old_lv.pid)
      ref = Process.monitor(old_guardian)
      Process.exit(old_guardian, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_guardian, :killed}, 1_000

      refute_receive {:write_started, _pid, _uid, _payload}, 200
      answer(kept, :ok)

      assert settled(lv) =~ "Third title"
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    # The phone reconnects and keeps an edit, a desktop tab keeps one too
    # (waiting for the phone's grid as well), and the phone's grid is then
    # mounted again. It must not wait for the desktop tab in turn, or each
    # waits for the other and neither edit is ever written.
    test "a grid mounted again while another tab waits for it writes its kept edit first", %{
      conn: conn,
      event: event
    } do
      old_lv = open_event(conn, event)
      edit(old_lv, "update_event_title", "First title")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000
      kill(old_lv)

      phone = open_event(conn, event)
      edit(phone, "update_event_title", "Phone title")

      desktop = open_event(conn, event)
      edit(desktop, "update_event_location", "Room 9")

      render_patch(phone, ~p"/dashboard/overview")
      render_patch(phone, ~p"/dashboard/calendar")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(first, :ok)

      assert_receive {:write_started, phone_write, _uid, %{summary: "Phone title"}}, 1_000
      refute_receive {:write_started, _pid, _uid, _payload}, 200
      answer(phone_write, :ok)

      assert_receive {:write_started, desktop_write, _uid, payload}, 1_000
      assert %{summary: "Phone title", location: "Room 9"} = payload
      answer(desktop_write, :ok)

      assert settled(desktop) =~ "Room 9"
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    # A LiveView still alive may be another open tab of the same organiser:
    # it goes on writing its own queue, and this tab's edit of the same
    # event waits until it has.
    test "another open tab writes its own queue, and an edit here waits for it", %{
      conn: conn,
      event: event
    } do
      other_tab = open_event(conn, event)

      edit(other_tab, "update_event_title", "First title")
      edit(other_tab, "update_event_location", "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "This tab")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(first, :ok)

      # Started once, by the other tab, and not by this one too.
      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, 1_000
      refute_receive {:write_started, _pid, _uid, _payload}, 200
      answer(second, :ok)
      assert settled(other_tab) =~ "Room 9"

      assert_receive {:write_started, this_tab, _uid, payload}, 1_000
      assert %{summary: "This tab", location: "Room 9"} = payload
      answer(this_tab, :ok)

      # The other tab still owns its grid's writes.
      edit(other_tab, "update_event_location", "Room 10")
      assert_receive {:write_started, later, _uid, %{location: "Room 10"}}, 1_000
      answer(later, :ok)

      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end
  end
end
