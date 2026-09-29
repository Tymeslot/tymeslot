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
