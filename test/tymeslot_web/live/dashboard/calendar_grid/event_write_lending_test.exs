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

  # Each write runs in a task the test waits to hear from; on a loaded machine
  # that can take longer than a second.
  @write_timeout 5_000

  import TymeslotWeb.CalendarGridWriteHelpers

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.Repo

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
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      old_guardian = WriteGuardian.whereis(old_lv.pid)
      guardian_ref = Process.monitor(old_guardian)
      kill(old_lv)

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")
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
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")
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
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")

      # The new grid goes first; the old guardian, which lent it the event,
      # then finishes its own queue.
      kill(lv)
      kill(old_lv)
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(first, :ok)

      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, @write_timeout
      refute_receive {:write_started, _pid, _uid, _payload}, 200
      answer(second, :ok)

      assert_receive {:write_started, third, _uid, payload}, @write_timeout
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

      assert_receive {:write_started, standup_write, _uid, %{summary: "Standup renamed"}},
                     @write_timeout

      tab_two = open_event(conn, review)
      edit(tab_two, "update_event_title", "Review renamed")

      assert_receive {:write_started, review_write, _uid, %{summary: "Review renamed"}},
                     @write_timeout

      kill(tab_one)
      kill(tab_two)

      lv = open_event(conn, event)
      edit(lv, "update_event_location", "Room 9")
      lv |> element("[id^='event-#{review.id}-']") |> render_click()
      edit(lv, "update_event_location", "Room 8")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(standup_write, :ok)
      assert_receive {:write_started, next, _uid, %{location: "Room 9"}}, @write_timeout
      answer(next, :ok)

      answer(review_write, :ok)
      assert_receive {:write_started, next, _uid, %{location: "Room 8"}}, @write_timeout
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
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      old_guardian = WriteGuardian.whereis(old_lv.pid)
      kill(old_lv)

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      Process.exit(old_guardian, :kill)

      # Well within the guardian's drain timeout.
      assert_receive {:write_started, kept, _uid, %{summary: "Third title"}}, @write_timeout
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
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      old_guardian = WriteGuardian.whereis(old_lv.pid)
      kill(old_lv)

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")

      # The new grid's guardian now drives its queue.
      kill(lv)
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      Process.exit(old_guardian, :kill)

      assert_receive {:write_started, kept, _uid, %{summary: "Third title"}}, @write_timeout
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
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "Third title")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(first, :ok)
      assert settled(old_lv) =~ "First title"
      assert_receive {:write_started, kept, _uid, %{summary: "Third title"}}, @write_timeout

      old_guardian = WriteGuardian.whereis(old_lv.pid)
      ref = Process.monitor(old_guardian)
      Process.exit(old_guardian, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_guardian, :killed}, @write_timeout

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
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout
      kill(old_lv)

      phone = open_event(conn, event)
      edit(phone, "update_event_title", "Phone title")

      desktop = open_event(conn, event)
      edit(desktop, "update_event_location", "Room 9")

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
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      lv = open_event(conn, event)
      edit(lv, "update_event_title", "This tab")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(first, :ok)

      # Started once, by the other tab, and not by this one too.
      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, @write_timeout
      refute_receive {:write_started, _pid, _uid, _payload}, 200
      answer(second, :ok)
      assert settled(other_tab) =~ "Room 9"

      assert_receive {:write_started, this_tab, _uid, payload}, @write_timeout
      assert %{summary: "This tab", location: "Room 9"} = payload
      answer(this_tab, :ok)

      # The other tab still owns its grid's writes.
      edit(other_tab, "update_event_location", "Room 10")
      assert_receive {:write_started, later, _uid, %{location: "Room 10"}}, @write_timeout
      answer(later, :ok)

      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end
  end

  describe "when another tab is writing one occurrence of a series" do
    setup %{integration: integration} do
      [event, other] =
        for time <- [~T[09:00:00], ~T[15:00:00]] do
          integration
          |> standup("Weekly", "Room 1", time)
          |> Changeset.change(provider: "google", recurring_event_id: "weekly-master")
          |> Repo.update!()
        end

      {:ok, event: event, other: other}
    end

    # The other tab's write, and this tab's edit kept behind it, were made on
    # the occurrence as it was; a write to all events made alongside them
    # would be partly undone when they land after it.
    test "a write to all events is refused here until that write has saved", %{
      conn: conn,
      event: event,
      other: other
    } do
      other_tab = open_event(conn, other)
      edit(other_tab, "update_event_title", "Their title")
      assert_receive {:write_started, first, _uid, %{summary: "Their title"}}, @write_timeout

      lv = open_event(conn, other)
      edit(lv, "update_event_title", "This tab")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      # Moves the other occurrence to 14:00 today, for all events.
      lv
      |> element("#calendar-grid")
      |> render_hook("event_dropped", %{
        "event-id" => to_string(event.id),
        "new-date" => Date.to_iso8601(Date.utc_today()),
        "new-hour" => "14",
        "new-minute" => "0",
        "new-end-hour" => "15",
        "new-end-minute" => "0"
      })

      lv
      |> element("#recurrence-prompt-modal [phx-value-scope='all']")
      |> render_click()

      assert render(lv) =~
               "A change to this series is still saving. Please make this change once it has saved."

      refute has_element?(lv, "#recurrence-prompt-modal")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(first, :ok)

      assert_receive {:write_started, kept, _uid, %{summary: "This tab"}}, @write_timeout
      answer(kept, :ok)
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end
  end
end
