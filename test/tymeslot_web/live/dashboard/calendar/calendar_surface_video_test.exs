defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceVideoTest do
  @moduledoc """
  Adding and removing an event's video call from the side panel, end to
  end: the room the organiser's video integration creates, the description
  written to the calendar, the row cached, and what the panel shows once
  the write has answered.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :video
  @moduletag :live

  import Mox
  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Repo

  # Room creation and the calendar write run in a supervised task.
  @task_timeout 5_000

  setup :verify_on_exit!

  setup %{conn: conn} do
    context = owner(conn)
    video = insert(:video_integration, user: context.user, name: "MiroTalk", is_active: true)
    review = event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])

    Map.merge(context, %{video: video, review: review, id: "event-#{review.id}"})
  end

  defp open_panel(lv, id),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:edit", %{"id" => id})

  defp stub_room_created(url) do
    body = Jason.encode!(%{"room_id" => "room-123", "meeting_url" => url})

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: body}}
    end)
  end

  defp expect_provider_update do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:provider_update, self(), payload})
      :ok
    end)
  end

  # Waits for the task that made the calendar write, then renders twice:
  # once for the LiveView to take its result, once for the surface to apply it.
  defp await_provider_update(lv) do
    assert_receive {:provider_update, task_pid, payload}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    payload
  end

  test "with one video integration, Add video call creates a room and shows Join", %{
    conn: conn,
    integration: integration,
    review: review,
    video: video,
    id: id
  } do
    stub_room_created("https://video.example.com/join/room-123")
    expect_provider_update()

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, id)
    lv |> element("#calendar-panel-video-add") |> render_click()

    payload = await_provider_update(lv)
    assert payload.description == "Join video call: https://video.example.com/join/room-123"

    assert has_element?(
             lv,
             ~s|#calendar-panel-join[href="https://video.example.com/join/room-123"]|
           )

    assert has_element?(lv, "#calendar-panel", "Saved")
    refute render(lv) =~ "Video room created."

    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, review.uid)
    assert row.video_link == "https://video.example.com/join/room-123"
    assert row.video_integration_id == video.id
  end

  test "with several video integrations, the chosen one creates the room", %{
    conn: conn,
    user: user,
    integration: integration,
    review: review,
    id: id
  } do
    other = insert(:video_integration, user: user, name: "Team rooms", is_active: true)
    stub_room_created("https://video.example.com/join/team")
    expect_provider_update()

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, id)

    refute has_element?(lv, "#calendar-panel-video-add")
    assert has_element?(lv, "#calendar-panel-video-choice option", "Team rooms")

    lv
    |> form("#calendar-panel-video-form")
    |> render_change(%{"video_integration_id" => to_string(other.id)})

    await_provider_update(lv)

    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, review.uid)
    assert row.video_integration_id == other.id
  end

  test "Remove link takes the call off the event", %{
    conn: conn,
    integration: integration,
    video: video
  } do
    link = "https://video.example.com/join/old-room"

    linked =
      event(integration, "work", "Linked", ~U[2026-10-15 09:00:00Z], 60,
        description: "Join video call: #{link}",
        video_link: link,
        video_integration_id: video.id
      )

    expect_provider_update()

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, "event-#{linked.id}")
    assert has_element?(lv, ~s|#calendar-panel-join[href="#{link}"]|)

    lv |> element("#calendar-panel-video-remove") |> render_click()

    payload = await_provider_update(lv)
    refute payload.description =~ link
    refute has_element?(lv, "#calendar-panel-join")
    assert has_element?(lv, "#calendar-panel-video-add")

    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, linked.uid)
    assert row.video_link == nil
  end

  test "a failed room creation puts the event back and says why", %{
    conn: conn,
    integration: integration,
    review: review,
    id: id
  } do
    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"room_id" => "room-123"})}}
    end)

    expect(Tymeslot.CalendarMock, :update_event, 0, fn _uid, _payload, _context -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, id)
    lv |> element("#calendar-panel-video-add") |> render_click()

    assert_eventually(fn ->
      render(lv) =~ "The video provider did not return a meeting link"
    end)

    assert has_element?(lv, "#calendar-panel-video-add")
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, review.uid)
    assert row.video_integration_id == nil
  end

  test "another organiser's video integration is ignored", %{conn: conn, user: user, id: id} do
    insert(:video_integration, user: user, name: "Team rooms", is_active: true)
    stranger = insert(:video_integration, user: insert(:user, []), is_active: true)
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      send(test_pid, :room_requested)
      {:ok, %Req.Response{status: 200, body: "{}"}}
    end)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, id)

    lv
    |> element("#calendar-canvas")
    |> render_hook("panel:video", %{"video_integration_id" => to_string(stranger.id)})

    refute_receive :room_requested, 300
    assert has_element?(lv, "#calendar-panel-video-field-1")
    refute has_element?(lv, "#calendar-panel-video-field-0")
    refute has_element?(lv, "#calendar-panel-join")
  end

  test "the calendar copy of a booking offers no video change", %{
    conn: conn,
    integration: integration
  } do
    copy = event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30)
    insert(:meeting, calendar_integration_id: integration.id, calendar_uid: copy.uid)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, "event-#{copy.id}")

    assert has_element?(lv, "#calendar-panel-video", "The video call belongs to the booking.")
    refute has_element?(lv, "#calendar-panel-video-add")
  end

  test "with no video integration the row says so", %{
    conn: conn,
    video: video,
    id: id
  } do
    Repo.delete!(video)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, id)

    assert has_element?(lv, "#calendar-panel-video", "No video integration connected.")
    refute has_element?(lv, "#calendar-panel-video-add")
  end

  test "an unknown video integration id is ignored", %{conn: conn, id: id} do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      send(test_pid, :room_requested)
      {:ok, %Req.Response{status: 200, body: "{}"}}
    end)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, id)

    lv
    |> element("#calendar-canvas")
    |> render_hook("panel:video", %{"video_integration_id" => "999999999"})

    refute_receive :room_requested, 300
    assert has_element?(lv, "#calendar-panel-video-add")
  end

  test "the row says the room is being created while the provider answers", %{
    conn: conn,
    id: id
  } do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      send(test_pid, {:room_requested, self()})

      receive do
        :release -> {:error, :timeout}
      end
    end)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, id)
    lv |> element("#calendar-panel-video-add") |> render_click()

    assert_receive {:room_requested, task_pid}, @task_timeout
    on_exit(fn -> send(task_pid, :release) end)

    assert has_element?(lv, "#calendar-panel-video", "Creating the video call…")
    assert has_element?(lv, "#calendar-panel-status", "Saving")
    refute has_element?(lv, "#calendar-panel-video-add")
  end

  test "a failed room puts the header back to a failure", %{conn: conn, id: id} do
    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"room_id" => "room-123"})}}
    end)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, id)
    lv |> element("#calendar-panel-video-add") |> render_click()

    assert_eventually(fn -> render(lv) =~ "The video provider did not return a meeting link" end)
    assert has_element?(lv, "#calendar-panel-status", "The change was put back.")
  end

  test "the calendar copy of a booking with a link still offers Join, but no change", %{
    conn: conn,
    integration: integration
  } do
    link = "https://video.example.com/join/booked"

    copy =
      event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30,
        video_link: link,
        description: "Join video call: #{link}"
      )

    insert(:meeting, calendar_integration_id: integration.id, calendar_uid: copy.uid)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, "event-#{copy.id}")

    assert has_element?(lv, ~s|#calendar-panel-join[href="#{link}"]|)
    assert has_element?(lv, "#calendar-panel-video", "The video call belongs to the booking.")
    refute has_element?(lv, "#calendar-panel-video-remove")
    refute has_element?(lv, "#calendar-panel-video-add")
  end

  test "a series room that is only restored settles the panel and shows the link", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    talk = insert(:video_integration, user: user, provider: "nextcloud_talk", is_active: true)
    url = "https://talk.example.org/call/room-weekly-sync"

    {:ok, _room} =
      EventVideoRoomQueries.insert(%{
        user_id: user.id,
        video_integration_id: talk.id,
        provider: "nextcloud_talk",
        calendar_integration_id: integration.id,
        event_uid: "series-1@google.com",
        provider_event_id: "series-1",
        room_id: "room-weekly-sync",
        lobby_opens_at: ~U[2026-10-01 08:45:00Z],
        ends_at: ~U[2026-12-01 10:00:00Z]
      })

    weekly =
      event(integration, "work", "Weekly sync", ~U[2026-10-16 09:00:00Z], 60,
        description: "Agenda\n\nJoin video call: #{url}",
        uid: "series-1_20261016T090000Z",
        provider_event_id: "series-1_20261016T090000Z",
        recurring_event_id: "series-1"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, "event-#{weekly.id}")

    lv
    |> form("#calendar-panel-video-form")
    |> render_change(%{"video_integration_id" => to_string(talk.id)})

    assert_eventually(fn -> has_element?(lv, ~s|#calendar-panel-join[href="#{url}"]|) end)
    assert has_element?(lv, "#calendar-panel-status", "Saved")
    refute has_element?(lv, "#calendar-panel-video", "Creating the video call")
  end

  describe "while the event moves to another calendar" do
    setup %{conn: conn, user: user, id: id} do
      insert(:video_integration, user: user, name: "Team rooms", is_active: true)

      other =
        insert(:calendar_integration,
          user: user,
          name: "Other account",
          provider: "google",
          is_active: true,
          calendar_list: [%{"id" => "other", "name" => "Other", "selected" => true}]
        )

      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
        send(test_pid, {:create_held, self()})

        receive do
          :release -> {:ok, CreatedEvent.new(payload.uid)}
        end
      end)

      stub(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_panel(lv, id)

      lv
      |> form("#calendar-panel-calendar-form")
      |> render_change(%{"calendar" => "#{other.id}:other"})

      assert_receive {:create_held, task_pid}, @task_timeout
      on_exit(fn -> send(task_pid, :release) end)
      %{lv: lv}
    end

    test "a video change is refused and the select shows the server's value", %{
      lv: lv,
      user: user
    } do
      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        send(test_pid, :room_requested)
        {:ok, %Req.Response{status: 200, body: "{}"}}
      end)

      assert has_element?(lv, "#calendar-panel-video-field-0")
      chosen = hd(Video.list_active_integrations(user.id))

      lv
      |> form("#calendar-panel-video-form")
      |> render_change(%{"video_integration_id" => to_string(chosen.id)})

      refute_receive :room_requested, 300
      assert has_element?(lv, "#calendar-panel-status", "moving to another calendar")
      assert has_element?(lv, "#calendar-panel-video-field-1")
    end
  end

  # Polls a condition the LiveView reaches once a background task answers,
  # rendering between attempts; fails after about a second.
  defp assert_eventually(fun, attempts \\ 20) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        receive do
        after
          50 -> assert_eventually(fun, attempts - 1)
        end
    end
  end
end
