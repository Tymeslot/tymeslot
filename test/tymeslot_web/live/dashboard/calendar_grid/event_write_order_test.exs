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

  import Tymeslot.Factory
  import TymeslotWeb.CalendarGridWriteHelpers

  alias Tymeslot.CalendarGrid.WriteGuardian

  setup :hold_writes

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

    # Leaving the calendar and coming straight back, before the browser has
    # confirmed the grid's removal, revives the grid LiveView had marked for
    # deletion, with the queue it had when it left. Its guardian has been
    # driving that queue since, so the grid must take it back rather than
    # drive it too, or each of them starts the next write.
    test "a grid shown again before it was removed writes the waiting edit once", %{
      conn: conn,
      event: event
    } do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "First title")
      edit(lv, "update_event_location", "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      leave_suspended(lv, ~p"/dashboard/overview")
      return_suspended(lv, ~p"/dashboard/calendar")

      answer(first, :ok)
      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, 1_000
      refute_receive {:write_started, _pid, _uid, _payload}, 200
      answer(second, :ok)

      settled(lv)
      refute_receive {:write_started, _pid, _uid, _payload}, 200
    end

    # The grid's guardian drives the queue from the moment the organiser
    # leaves the calendar, and hears every write's result itself; the grid,
    # which LiveView deletes only once the browser confirms it is gone, must
    # not be handed the result as well.
    test "a write answering while the grid waits to be removed starts the next one once", %{
      conn: conn,
      event: event
    } do
      lv = open_event(conn, event)

      edit(lv, "update_event_title", "First title")
      edit(lv, "update_event_location", "Room 9")
      assert_receive {:write_started, first, _uid, %{summary: "First title"}}, 1_000

      leave_suspended(lv, ~p"/dashboard/overview")
      answer(first, :ok)
      :ok = :sys.resume(lv.pid)

      assert_receive {:write_started, second, _uid, %{location: "Room 9"}}, 1_000
      refute_receive {:write_started, _pid, _uid, _payload}, 200
      answer(second, :ok)
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

  # Patches `lv` to `path`, away from the calendar, and leaves the
  # LiveView suspended with the browser's notice that it will remove the
  # grid not yet taken: the LiveView is let through the patch alone and
  # suspended again before the notice, sent once the patch has rendered,
  # arrives. Whatever is sent to it meanwhile queues up behind the notice.
  defp leave_suspended(lv, path) do
    :ok = :sys.suspend(lv.pid)
    leave = Task.async(fn -> render_patch(lv, path) end)
    await_message(lv.pid, &live_patch?/1)
    :ok = :sys.resume(lv.pid)
    :ok = :sys.suspend(lv.pid)
    Task.await(leave)
  end

  # Patches the suspended `lv` to `path` once the patch is queued, so that
  # it reaches the LiveView ahead of the browser's confirmation that the
  # grid is gone, and LiveView revives the grid instead of mounting it.
  defp return_suspended(lv, path) do
    return = Task.async(fn -> render_patch(lv, path) end)
    await_message(lv.pid, &live_patch?/1)
    :ok = :sys.resume(lv.pid)
    Task.await(return)
  end

  defp live_patch?(message), do: match?(%Phoenix.Socket.Message{event: "live_patch"}, message)

  defp await_message(pid, match?, tries \\ 100) do
    {:messages, messages} = Process.info(pid, :messages)

    cond do
      Enum.any?(messages, match?) -> :ok
      tries == 0 -> flunk("#{inspect(pid)} never received the message")
      true -> receive(after: (10 -> await_message(pid, match?, tries - 1)))
    end
  end
end
