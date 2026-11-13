defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceWriteOrderTest do
  @moduledoc """
  Quick successive edits of one event on the calendar reach the calendar
  one at a time, in the order the organiser made them, and a failure takes
  back only its own change; edits of different events are not held up by
  each other. Writes still waiting when the calendar goes (the connection
  drops, or the organiser opens another dashboard page) are made by the
  LiveView's write guardian (`Tymeslot.CalendarGrid.WriteGuardian`).

  The calendar mock holds every write until the test releases it, so the
  tests decide when, and how, each write answers.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory, only: [insert: 2]
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers
  import TymeslotWeb.CalendarSurfaceWriteHelpers

  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  # Each write runs in a task the test waits to hear from; on a loaded machine
  # that can take longer than a second.
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

  defp cached(integration, event) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
    row
  end

  describe "two quick edits of one event" do
    test "reach the calendar in the order they were made", %{
      conn: conn,
      integration: integration,
      standup: standup
    } do
      lv = open_event(conn, standup)

      rename(lv, "First title")
      rename(lv, "Second title")

      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout
      refute_receive {:write_started, _pid, _uid, _payload}, 100

      answer(first, :ok)

      assert_receive {:write_started, second, _uid, %{summary: "Second title"}}, @write_timeout
      answer(second, :ok)
      settled(lv)

      assert cached(integration, standup).summary == "Second title"
    end

    test "a failure of the first takes back only its own change", %{
      conn: conn,
      integration: integration,
      standup: standup
    } do
      lv = open_event(conn, standup)

      rename(lv, "Renamed")
      relocate(lv, "Room 9")

      assert_receive {:write_started, first, _uid, %{summary: "Renamed"}}, @write_timeout
      answer(first, {:error, :unauthorized})

      # The second write still runs, carrying its own change and not the one
      # the calendar refused.
      assert_receive {:write_started, second, _uid, payload}, @write_timeout
      assert %{summary: "Team Standup", location: "Room 9"} = payload

      assert settled(lv) =~ "Failed to update event"

      # The panel keeps the change that is still being written and has put
      # back the title the calendar refused.
      assert has_element?(lv, "#calendar-panel-title[value='Team Standup']")
      assert has_element?(lv, "#calendar-panel-location[value='Room 9']")

      answer(second, :ok)
      settled(lv)

      assert %{summary: "Team Standup", location: "Room 9"} = cached(integration, standup)
    end
  end

  test "an edit made while a video room is being added keeps the room's join line", %{
    conn: conn,
    user: user,
    standup: standup
  } do
    insert(:video_integration,
      user: user,
      is_active: true,
      provider: "custom",
      custom_meeting_url: "https://meet.example.com/{{meeting_id}}"
    )

    lv = open_event(conn, standup)

    lv |> element("#calendar-panel-video-add") |> render_click()
    assert_receive {:write_started, first, _uid, %{description: with_room}}, @write_timeout
    assert with_room =~ "Join video call: https://meet.example.com/"

    rename(lv, "Renamed")
    refute_receive {:write_started, _pid, _uid, _payload}, 100

    answer(first, :ok)

    # Written onto the event as the calendar now holds it, not onto the copy
    # the panel had when the title was changed, which had no link yet.
    assert_receive {:write_started, second, _uid, %{summary: "Renamed", description: ^with_room}},
                   @write_timeout

    answer(second, :ok)
  end

  test "edits of two different events are written at the same time", %{
    conn: conn,
    integration: integration,
    standup: standup
  } do
    review = event(integration, "work", "Design Review", ~U[2026-10-14 13:00:00Z])

    lv = open_event(conn, standup)
    rename(lv, "Standup renamed")
    lv |> open_panel(review) |> rename("Review renamed")

    assert_receive {:write_started, first, uid_one, _payload}, @write_timeout
    assert_receive {:write_started, second, uid_two, _payload}, @write_timeout
    assert Enum.sort([uid_one, uid_two]) == Enum.sort([standup.uid, review.uid])

    answer(first, :ok)
    answer(second, :ok)
  end

  test "a single failing edit is reverted", %{
    conn: conn,
    integration: integration,
    standup: standup
  } do
    lv = open_event(conn, standup)

    rename(lv, "Renamed")
    assert_receive {:write_started, write, _uid, %{summary: "Renamed"}}, @write_timeout
    answer(write, {:error, :unauthorized})

    assert settled(lv) =~ "Failed to update event"
    assert has_element?(lv, "#calendar-panel-title[value='Team Standup']")
    assert cached(integration, standup).summary == "Team Standup"
  end

  describe "when the calendar is gone before a waiting edit has started" do
    # The waiting edit lives only in the LiveView; its guardian makes it once
    # the write ahead of it answers, onto the event as that write left it.
    test "an edit queued behind a running one still reaches the calendar", %{
      conn: conn,
      standup: standup
    } do
      lv = open_event(conn, standup)

      rename(lv, "First title")
      relocate(lv, "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      kill(lv)
      refute_receive {:write_started, _pid, _uid, _payload}, 100

      answer(first, :ok)

      assert_receive {:write_started, second, _uid, payload}, @write_timeout
      assert %{summary: "First title", location: "Room 9"} = payload
      answer(second, :ok)

      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    test "leaving the calendar for another dashboard page still makes it", %{
      conn: conn,
      standup: standup
    } do
      lv = open_event(conn, standup)

      rename(lv, "First title")
      rename(lv, "Second title")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      # The surface is unmounted while the LiveView lives on.
      render_patch(lv, ~p"/dashboard/overview")
      answer(first, :ok)

      assert_receive {:write_started, second, _uid, %{summary: "Second title"}}, @write_timeout
      answer(second, :ok)
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    # The surface mounted again takes back the queue its guardian was
    # driving, so a new edit of the event waits behind the edit still being
    # written and is made onto the event as that one leaves it.
    test "an edit made on returning to the calendar waits behind the ones still saving", %{
      conn: conn,
      standup: standup
    } do
      lv = open_event(conn, standup)

      rename(lv, "First title")
      relocate(lv, "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      render_patch(lv, ~p"/dashboard/overview")
      answer(first, :ok)
      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, @write_timeout

      render_patch(lv, ~p"/dashboard/calendar")
      lv |> open_panel(standup) |> rename("Third title")
      refute_receive {:write_started, _pid, _uid, _payload}, 200

      answer(second, :ok)

      assert_receive {:write_started, third, _uid, payload}, @write_timeout
      assert %{summary: "Third title", location: "Room 9"} = payload
      answer(third, :ok)

      settled(lv)
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    # The replacement guardian is handed the queue with the write already
    # running; its answer must reach it, not the guardian that crashed.
    test "a guardian started again after a crash still hears the running write", %{
      conn: conn,
      standup: standup
    } do
      lv = open_event(conn, standup)

      rename(lv, "First title")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout

      crashed = WriteGuardian.whereis(lv.pid)
      Process.exit(crashed, :kill)
      eventually(fn -> WriteGuardian.whereis(lv.pid) == nil end)

      relocate(lv, "Room 9")
      assert is_pid(WriteGuardian.whereis(lv.pid))

      kill(lv)
      answer(first, :ok)

      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, @write_timeout
      answer(second, :ok)
    end

    test "nothing is written twice once every edit has answered", %{
      conn: conn,
      integration: integration,
      standup: standup
    } do
      lv = open_event(conn, standup)

      rename(lv, "First title")
      rename(lv, "Second title")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, @write_timeout
      answer(first, :ok)
      assert_receive {:write_started, second, _uid, %{summary: "Second title"}}, @write_timeout
      answer(second, :ok)
      settled(lv)
      assert cached(integration, standup).summary == "Second title"

      guardian = WriteGuardian.whereis(lv.pid)
      assert is_pid(guardian)
      ref = Process.monitor(guardian)

      kill(lv)

      # With nothing left to finish it stops, having written nothing.
      assert_receive {:DOWN, ^ref, :process, ^guardian, :normal}, @write_timeout
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end
  end
end
