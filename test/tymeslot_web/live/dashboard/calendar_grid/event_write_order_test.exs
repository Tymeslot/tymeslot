defmodule TymeslotWeb.Dashboard.CalendarGrid.EventWriteOrderTest do
  @moduledoc """
  Quick successive edits of one grid event reach the calendar one at a time,
  in the order the organiser made them, and a failure takes back only its own
  change. Edits of different events are not held up by each other.

  The calendar mock holds every write until the test releases it, so the
  tests decide when, and how, each write answers.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.CalendarGrid.WriteGuardian

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    integration = insert(:calendar_integration, user: user, is_active: true)

    test_pid = self()

    Mox.stub(Tymeslot.CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:write_started, self(), uid, payload})

      receive do
        {:answer, answer} -> answer
      end
    end)

    {:ok, conn: conn, user: user, integration: integration}
  end

  describe "two quick edits of one event" do
    setup %{integration: integration} do
      {:ok, event: standup(integration, "Team Standup", "Room 101")}
    end

    test "reach the calendar in the order they were made", %{conn: conn, event: event} do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "First title")
      edit(lv, "update_event_title", "Second title")

      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000
      refute_receive {:write_started, _pid, _uid, _payload}, 100

      answer(first, :ok)

      assert_receive {:write_started, second, _uid, %{summary: "Second title"}}, 1_000
      answer(second, :ok)

      assert settled(lv) =~ "Second title"
    end

    test "a failure of the first takes back only its own change", %{conn: conn, event: event} do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "Renamed")
      edit(lv, "update_event_location", "Room 9")

      assert_receive {:write_started, first, _uid, %{summary: "Renamed"}}, 1_000
      answer(first, {:error, :unauthorized})

      # The second write still runs, carrying its own change and not the one
      # the calendar refused.
      assert_receive {:write_started, second, _uid, payload}, 1_000
      assert %{summary: "Team Standup", location: "Room 9"} = payload

      html = settled(lv)
      assert html =~ "Failed to update event"
      assert html =~ "Room 9"
      refute html =~ "Renamed"

      answer(second, :ok)

      html = settled(lv)
      assert html =~ "Room 9"
      refute html =~ "Renamed"
    end
  end

  test "an edit made while a video room is being added keeps the room's join line", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    video =
      insert(:video_integration,
        user: user,
        is_active: true,
        provider: "custom",
        custom_meeting_url: "https://meet.example.com/{{meeting_id}}"
      )

    event = standup(integration, "Team Standup", "Room 101")
    lv = open_event(conn, event)

    lv |> element(~s|button[phx-value-video_integration_id="#{video.id}"]|) |> render_click()
    assert_receive {:write_started, first, _uid, %{description: with_room}}, 1_000
    assert with_room =~ "Join video call: https://meet.example.com/"

    edit(lv, "update_event_title", "Renamed")
    refute_receive {:write_started, _pid, _uid, _payload}, 100

    answer(first, :ok)

    # Written onto the event as the calendar now holds it, not onto the copy
    # the grid had when the title was changed, which had no link yet.
    assert_receive {:write_started, second, _uid, %{summary: "Renamed", description: ^with_room}},
                   1_000

    answer(second, :ok)
  end

  test "edits of two different events are written at the same time", %{
    conn: conn,
    integration: integration
  } do
    standup = standup(integration, "Team Standup", "Room 101")
    review = standup(integration, "Design Review", "Room 202", ~T[14:00:00])

    lv = open_event(conn, standup)
    edit(lv, "update_event_title", "Standup renamed")
    lv |> element("[id^='event-#{review.id}-']") |> render_click()
    edit(lv, "update_event_title", "Review renamed")

    assert_receive {:write_started, first, uid_one, _payload}, 1_000
    assert_receive {:write_started, second, uid_two, _payload}, 1_000
    assert Enum.sort([uid_one, uid_two]) == Enum.sort([standup.uid, review.uid])

    answer(first, :ok)
    answer(second, :ok)
  end

  test "a single failing edit is reverted", %{conn: conn, integration: integration} do
    event = standup(integration, "Team Standup", "Room 101")
    lv = open_event(conn, event)

    edit(lv, "update_event_title", "Renamed")
    assert render(lv) =~ "Renamed"

    assert_receive {:write_started, write, _uid, %{summary: "Renamed"}}, 1_000
    answer(write, {:error, :unauthorized})

    html = settled(lv)
    assert html =~ "Failed to update event"
    assert html =~ "Team Standup"
    refute html =~ "Renamed"
  end

  describe "when the grid is gone before a waiting edit has started" do
    setup %{integration: integration} do
      {:ok, event: standup(integration, "Team Standup", "Room 101")}
    end

    # The waiting edit lives only in the LiveView; its guardian makes it once
    # the write ahead of it answers, onto the event as that write left it.
    test "an edit queued behind a running one still reaches the calendar", %{
      conn: conn,
      event: event
    } do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "First title")
      edit(lv, "update_event_location", "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      kill(lv)
      refute_receive {:write_started, _pid, _uid, _payload}, 100

      answer(first, :ok)

      assert_receive {:write_started, second, _uid, payload}, 1_000
      assert %{summary: "First title", location: "Room 9"} = payload
      answer(second, :ok)

      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    test "leaving the calendar for another dashboard page still makes it", %{
      conn: conn,
      event: event
    } do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "First title")
      edit(lv, "update_event_title", "Second title")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      # The grid is unmounted while the LiveView lives on.
      render_patch(lv, ~p"/dashboard/overview")
      answer(first, :ok)

      assert_receive {:write_started, second, _uid, %{summary: "Second title"}}, 1_000
      answer(second, :ok)
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    # The grid mounted again takes back the queue its guardian was driving,
    # so a new edit of the event waits behind the edit still being written
    # and is made onto the event as that one leaves it.
    test "an edit made on returning to the calendar waits behind the ones still saving", %{
      conn: conn,
      event: event
    } do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "First title")
      edit(lv, "update_event_location", "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      render_patch(lv, ~p"/dashboard/overview")
      answer(first, :ok)
      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, 1_000

      render_patch(lv, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()
      edit(lv, "update_event_title", "Third title")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(second, :ok)

      assert_receive {:write_started, third, _uid, payload}, 1_000
      assert %{summary: "Third title", location: "Room 9"} = payload
      answer(third, :ok)

      assert settled(lv) =~ "Third title"
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    # The replacement guardian is handed the queue with the write already
    # running; its answer must reach it, not the guardian that crashed.
    test "a guardian started again after a crash still hears the running write", %{
      conn: conn,
      event: event
    } do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "First title")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      crashed = WriteGuardian.whereis(lv.pid)
      Process.exit(crashed, :kill)
      eventually(fn -> WriteGuardian.whereis(lv.pid) == nil end)

      edit(lv, "update_event_location", "Room 9")
      assert is_pid(WriteGuardian.whereis(lv.pid))

      kill(lv)
      answer(first, :ok)

      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, 1_000
      answer(second, :ok)
    end

    test "nothing is written twice once every edit has answered", %{conn: conn, event: event} do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "First title")
      edit(lv, "update_event_title", "Second title")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000
      answer(first, :ok)
      assert_receive {:write_started, second, _uid, %{summary: "Second title"}}, 1_000
      answer(second, :ok)
      assert settled(lv) =~ "Second title"

      guardian = WriteGuardian.whereis(lv.pid)
      assert is_pid(guardian)
      ref = Process.monitor(guardian)

      kill(lv)

      # With nothing left to finish it stops, having written nothing.
      assert_receive {:DOWN, ^ref, :process, ^guardian, :normal}, 1_000
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end
  end

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

  defp standup(integration, summary, location, time \\ ~T[10:00:00]) do
    today = Date.utc_today()

    insert(:provider_calendar_event, %{
      calendar_integration: integration,
      summary: summary,
      location: location,
      start_at: DateTime.new!(today, time, "Etc/UTC"),
      end_at: DateTime.new!(today, Time.add(time, 3600), "Etc/UTC"),
      all_day: false
    })
  end

  defp open_event(conn, event) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("[id^='event-#{event.id}-']") |> render_click()
    lv
  end

  defp edit(lv, event_name, value),
    do: lv |> element("#calendar-grid") |> render_hook(event_name, %{"value" => value})

  defp kill(lv) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(lv.pid)
    Process.exit(lv.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 1_000
  end

  # Answers the held write and waits for its task to finish, by which time the
  # result is on its way to the LiveView.
  defp answer(write, answer) do
    ref = Process.monitor(write)
    send(write, {:answer, answer})
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000
  end

  # The LiveView hands a write's result on to the grid with `send_update/2`,
  # a message to itself queued behind whatever else is waiting, so the first
  # render only lets that update through and the second one shows it.
  defp settled(lv) do
    render(lv)
    render(lv)
  end
end
