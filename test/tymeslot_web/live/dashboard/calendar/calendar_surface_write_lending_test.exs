defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceWriteLendingTest do
  @moduledoc """
  When the new calendar mounts in a new LiveView while another of the
  organiser's LiveViews still has writes for an event (an old one whose
  connection dropped, or another open tab), its edits of that event wait
  until the other has finished with it, and then start from the event as
  those writes left it (see "A grid mounted in another LiveView" in
  `Tymeslot.CalendarGrid.WriteGuardian`).

  The calendar mock holds every write until the test releases it. Ported
  from the old calendar's `EventWriteLendingTest`.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers
  import TymeslotWeb.CalendarSurfaceWriteHelpers

  alias Tymeslot.CalendarGrid.WriteGuardian

  @write_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    hold_writes()

    standup =
      event(context.integration, "work", "Team Standup", ~U[2026-10-14 09:00:00Z], 60,
        location: "Room 101"
      )

    Map.put(context, :standup, standup)
  end

  # The old LiveView's guardian is still writing its queue; the new calendar
  # waits for the event until it has finished, so an edit made there runs
  # after the older ones rather than racing them to the calendar.
  test "a new edit of the event waits behind the older ones still saving", %{
    conn: conn,
    standup: standup
  } do
    old_lv = open_event(conn, standup)

    rename(old_lv, "First title")
    relocate(old_lv, "Room 9")
    assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

    old_guardian = WriteGuardian.whereis(old_lv.pid)
    guardian_ref = Process.monitor(old_guardian)
    kill(old_lv)

    lv = open_event(conn, standup)
    rename(lv, "Third title")
    refute_receive {:write_started, _pid, _uid, _payload}, 200

    answer(first, :ok)

    assert_receive {:write_started, second, _uid, payload}, @write_timeout
    assert %{summary: "First title", location: "Room 9"} = payload
    refute_receive {:write_started, _pid, _uid, _payload}, 200

    answer(second, :ok)

    assert_receive {:write_started, third, _uid, payload}, @write_timeout
    assert %{summary: "Third title", location: "Room 9"} = payload

    # Its queue written, the old guardian stops.
    assert_receive {:DOWN, ^guardian_ref, :process, ^old_guardian, :normal}, @write_timeout

    answer(third, :ok)
    settled(lv)
    refute_receive {:write_started, _pid, _uid, _payload}, 200
  end

  # After a short drop the server often notices the old connection only at
  # the heartbeat timeout, so the old LiveView still lives when the calendar
  # mounts again, and goes on writing its queue until it is gone.
  test "an edit made while the old LiveView still lives never lands before its older edits", %{
    conn: conn,
    standup: standup
  } do
    old_lv = open_event(conn, standup)

    rename(old_lv, "First title")
    relocate(old_lv, "Room 9")
    assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

    lv = open_event(conn, standup)
    rename(lv, "Third title")
    refute_receive {:write_started, _pid, _uid, _payload}, 200

    kill(old_lv)
    answer(first, :ok)

    assert_receive {:write_started, second, _uid, payload}, @write_timeout
    assert %{summary: "First title", location: "Room 9"} = payload
    refute_receive {:write_started, _pid, _uid, _payload}, 200

    answer(second, :ok)

    # Made onto the event as the older edits left it.
    assert_receive {:write_started, third, _uid, payload}, @write_timeout
    assert %{summary: "Third title", location: "Room 9"} = payload
    answer(third, :ok)

    settled(lv)
    refute_receive {:write_started, _pid, _uid, _payload}, 200
  end

  # A guardian killed outright never releases the events it lent; the new
  # calendar's guardian notices it is gone and releases them in its place.
  test "an edit kept for an event whose old guardian is killed outright still starts", %{
    conn: conn,
    standup: standup
  } do
    old_lv = open_event(conn, standup)
    rename(old_lv, "First title")
    assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

    old_guardian = WriteGuardian.whereis(old_lv.pid)
    kill(old_lv)

    lv = open_event(conn, standup)
    rename(lv, "Third title")
    refute_receive {:write_started, _pid, _uid, _payload}, 200

    Process.exit(old_guardian, :kill)

    # Well within the guardian's drain timeout.
    assert_receive {:write_started, kept, _uid, %{summary: "Third title"}}, @write_timeout
    answer(kept, :ok)
    answer(first, :ok)

    settled(lv)
    refute_receive {:write_started, _pid, _uid, _payload}, 200
  end

  # The phone reconnects and keeps an edit, a desktop tab keeps one too
  # (waiting for the phone's calendar as well), and the phone's calendar is
  # then mounted again. It must not wait for the desktop tab in turn, or each
  # waits for the other and neither edit is ever written.
  test "a calendar mounted again while another tab waits for it writes its kept edit first", %{
    conn: conn,
    standup: standup
  } do
    old_lv = open_event(conn, standup)
    rename(old_lv, "First title")
    assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout
    kill(old_lv)

    phone = open_event(conn, standup)
    rename(phone, "Phone title")

    desktop = open_event(conn, standup)
    relocate(desktop, "Room 9")

    render_patch(phone, ~p"/dashboard/overview")
    render_patch(phone, ~p"/dashboard/calendar")
    refute_receive {:write_started, _pid, _uid, _payload}, 200

    answer(first, :ok)

    assert_receive {:write_started, phone_write, _uid, %{summary: "Phone title"}},
                   @write_timeout

    refute_receive {:write_started, _pid, _uid, _payload}, 200
    answer(phone_write, :ok)

    assert_receive {:write_started, desktop_write, _uid, payload}, @write_timeout
    assert %{summary: "Phone title", location: "Room 9"} = payload
    answer(desktop_write, :ok)

    settled(desktop)
    refute_receive {:write_started, _pid, _uid, _payload}, 200
  end

  # A LiveView still alive may be another open tab of the same organiser: it
  # goes on writing its own queue, and this tab's edit of the same event
  # waits until it has.
  test "another open tab writes its own queue, and an edit here waits for it", %{
    conn: conn,
    standup: standup
  } do
    other_tab = open_event(conn, standup)

    rename(other_tab, "First title")
    relocate(other_tab, "Room 9")
    assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

    lv = open_event(conn, standup)
    rename(lv, "This tab")
    refute_receive {:write_started, _pid, _uid, _payload}, 200

    answer(first, :ok)

    # Started once, by the other tab, and not by this one too.
    assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, @write_timeout
    refute_receive {:write_started, _pid, _uid, _payload}, 200
    answer(second, :ok)
    settled(other_tab)

    assert_receive {:write_started, this_tab, _uid, payload}, @write_timeout
    assert %{summary: "This tab", location: "Room 9"} = payload
    answer(this_tab, :ok)

    # The other tab still owns its calendar's writes.
    relocate(other_tab, "Room 10")
    assert_receive {:write_started, later, _uid, %{location: "Room 10"}}, @write_timeout
    answer(later, :ok)

    refute_receive {:write_started, _pid, _uid, _payload}, 200
  end
end
