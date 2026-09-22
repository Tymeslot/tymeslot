defmodule TymeslotWeb.Dashboard.CalendarGrid.InlineEditVideoTest do
  @moduledoc """
  Picking a video provider for an event in the dashboard calendar grid, which
  is an edit in its own right: on its own it makes a room, tells the calendar
  about it and answers the organiser.

  Driven through the grid the way an organiser drives it — open the event,
  press a button in the picker — so a change that never leaves the socket
  cannot pass.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :video
  @moduletag :live

  import Mox
  import Plug.Conn
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption

  @rooms_path "/ocs/v2.php/apps/spreed/api/v4/room"
  @password_required ~s({"ocs":{"meta":{"status":"failure","statuscode":400,"message":""},"data":{"error":"password","message":"Password needs to be set"}}})

  setup %{conn: conn} do
    stub(Tymeslot.CalendarMock, :update_event, fn _uid, _event_data, _context -> :ok end)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    calendar = insert(:calendar_integration, user: user, is_active: true)

    %{conn: conn, user: user, calendar: calendar}
  end

  test "picking a provider on its own makes a room, tells the calendar and says so", %{
    conn: conn,
    user: user,
    calendar: calendar
  } do
    video = custom_video_integration(user)
    event = insert_event(calendar, description: "Agenda")

    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn uid, event_data, _context ->
      send(test_pid, {:calendar_told, uid, event_data.description})
      :ok
    end)

    lv = open_event(conn, event)

    lv |> element(picker_button(video.id)) |> render_click()

    assert_receive {:calendar_told, uid, description}, 2_000
    assert uid == event.uid
    assert description =~ "Agenda"
    assert description =~ "Join video call: https://meet.example.com/"

    eventually(fn -> assert render(lv) =~ "Video room created." end)

    assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(calendar.id, event.uid)
    assert row.video_integration_id == video.id
    assert row.video_link =~ ~r|\Ahttps://meet\.example\.com/[0-9a-f]{16}\z|
    assert row.description == description
  end

  test "clearing the provider on its own takes the link off and says so", %{
    conn: conn,
    user: user,
    calendar: calendar
  } do
    video = custom_video_integration(user)

    event =
      insert_event(calendar,
        video_integration_id: video.id,
        video_link: "https://meet.example.com/abc",
        description: "Agenda\n\nJoin video call: https://meet.example.com/abc"
      )

    lv = open_event(conn, event)

    lv |> element(picker_button("")) |> render_click()

    eventually(fn -> assert render(lv) =~ "Video link removed." end)

    assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(calendar.id, event.uid)
    assert row.video_integration_id == nil
    assert row.video_link == nil
    assert row.description == "Agenda"
  end

  test "a server that refuses to make rooms says which setting refuses it", %{
    conn: conn,
    user: user,
    calendar: calendar
  } do
    host = "refuses-rooms.example.com"
    talk = talk_integration(user, host)
    rooms_url = "https://#{host}#{@rooms_path}"

    # The organiser's own Nextcloud, whose Talk settings force a password on
    # public conversations: the credentials are fine, the server simply will
    # not make the room.
    stub(HTTPClientMock, :request, fn
      :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: ocs([])}}

      :post, ^rooms_url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: @password_required}}
    end)

    event = insert_event(calendar, description: "Agenda")

    lv = open_event(conn, event)

    lv |> element(picker_button(talk.id)) |> render_click()

    eventually(fn ->
      assert render(lv) =~ "turn off the password requirement for public conversations"
    end)

    # The picker goes back to the choice the organiser could see before they
    # pressed it, rather than showing a provider the event never got.
    assert has_element?(lv, picker_button("") <> ".border-turquoise-400")
    refute has_element?(lv, picker_button(talk.id) <> ".border-turquoise-400")

    assert {:ok, %{video_integration_id: nil, video_link: nil, description: "Agenda"}} =
             ProviderCalendarEventQueries.get_by_uid(calendar.id, event.uid)
  end

  test "the room a provider keeps is recorded, so the clean-up paths find it", %{
    conn: conn,
    user: user,
    calendar: calendar
  } do
    host = "grid-picker.example.com"
    talk = talk_integration(user, host)
    rooms_url = "https://#{host}#{@rooms_path}"

    # Plays the organiser's Nextcloud server, which holds no conversation
    # until one is created.
    stub(HTTPClientMock, :request, fn
      :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: ocs([])}}

      :post, ^rooms_url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 201, body: ocs(%{"token" => "pick0001"})}}
    end)

    event = insert_event(calendar, description: "Agenda")

    lv = open_event(conn, event)

    lv |> element(picker_button(talk.id)) |> render_click()

    eventually(fn -> assert render(lv) =~ "Video room created." end)

    assert [%{room_id: "pick0001", video_integration_id: video_integration_id}] =
             EventVideoRoomQueries.list_for_identifiers(calendar.id, [event.uid])

    assert video_integration_id == talk.id
  end

  test "pressing the provider the event already has changes nothing", %{
    conn: conn,
    user: user,
    calendar: calendar
  } do
    video = custom_video_integration(user)

    event =
      insert_event(calendar,
        video_integration_id: video.id,
        video_link: "https://meet.example.com/abc",
        description: "Agenda\n\nJoin video call: https://meet.example.com/abc"
      )

    # Any call to a provider from here is a room the organiser did not ask
    # for; a templated link needs no round trip, so the assertions below are
    # what catch one being made.

    lv = open_event(conn, event)

    html = lv |> element(picker_button(video.id)) |> render_click()

    refute html =~ "turn off the password requirement"
    refute render(lv) =~ "Video room created."

    assert {:ok, %{video_link: "https://meet.example.com/abc"}} =
             ProviderCalendarEventQueries.get_by_uid(calendar.id, event.uid)
  end

  defp open_event(conn, event) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("[id^='event-#{event.id}-']") |> render_click()
    lv
  end

  defp picker_button(id), do: ~s|button[phx-value-video_integration_id="#{id}"]|

  defp insert_event(calendar, attrs) do
    today = Date.utc_today()

    insert(
      :provider_calendar_event,
      Enum.into(attrs, %{
        calendar_integration: calendar,
        summary: "Planning",
        location: "",
        attendees: [],
        all_day: false,
        start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC")
      })
    )
  end

  # A templated link needs no provider round trip, so a room is made from the
  # event's own uid and the test stays about the grid.
  defp custom_video_integration(user) do
    insert(:video_integration,
      user: user,
      is_active: true,
      provider: "custom",
      custom_meeting_url: "https://meet.example.com/{{meeting_id}}"
    )
  end

  defp talk_integration(user, host) do
    base_url = "https://" <> host

    insert(:video_integration,
      user: user,
      is_active: true,
      provider: "nextcloud_talk",
      base_url: base_url,
      client_id_encrypted: Encryption.encrypt("organiser"),
      client_secret_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy"),
      provider_account_id: base_url <> "||organiser"
    )
  end

  defp ocs(data), do: Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
end
