defmodule Tymeslot.CalendarGrid.AllDayTalkConversationTest do
  @moduledoc """
  An all-day event created on the calendar grid with Nextcloud Talk gets its
  conversation, whose lobby opens as the event's first day begins anywhere:
  the same moment the grid records for the room, from one shared rule.

  The calendar provider and the HTTP client (playing the Nextcloud server)
  are stubbed.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Security.Encryption

  @server "https://allday.talk.example.com"
  @room_api @server <> "/ocs/v2.php/apps/spreed/api/v4/room"
  @token "allday12"

  setup :set_mox_global
  setup :verify_on_exit!

  test "creates the conversation for an all-day event, its lobby opening as the first day begins" do
    user = insert(:user)
    calendar = insert(:calendar_integration, user: user, is_active: true)

    talk =
      insert(:video_integration,
        user: user,
        name: "Nextcloud Talk",
        provider: "nextcloud_talk",
        base_url: @server,
        api_key_encrypted: nil,
        client_id_encrypted: Encryption.encrypt("organiser"),
        client_secret_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy"),
        provider_account_id: @server <> "||organiser"
      )

    test = self()

    expect(HTTPClientMock, :request, fn :get, _list_url, _body, _headers, _opts ->
      ocs(200, [])
    end)

    expect(HTTPClientMock, :request, fn :post, @room_api, body, _headers, _opts ->
      send(test, {:created, Jason.decode!(body)})
      ocs(201, %{"token" => @token})
    end)

    expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
      {:ok, "allday-uid"}
    end)

    # As the create form sends an all-day event from 1 to 2 October: Dates,
    # with the exclusive end.
    payload = %{
      creating: %{
        title: "Offsite",
        integration_id: calendar.id,
        calendar_id: "primary",
        attendees: [],
        all_day: true,
        video_integration_id: talk.id
      },
      user_id: user.id,
      all_day: true,
      start_at: ~D[2026-10-01],
      end_at: ~D[2026-10-03]
    }

    assert {:ok, result} = EventCreation.run_create_event(payload)
    assert result.video_room_id == @token

    # 14 hours before midnight UTC on 1 October, the earliest the day begins.
    opens_at = ~U[2026-09-30 10:00:00Z]

    assert_received {:created, %{"roomName" => "Offsite", "lobbyState" => 1} = created}
    assert created["lobbyTimer"] == DateTime.to_unix(opens_at)

    assert %EventVideoRoomSchema{room_id: @token, lobby_opens_at: ^opens_at} =
             Repo.get_by!(EventVideoRoomSchema, room_id: @token)
  end

  defp ocs(status, data) do
    body = Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
    {:ok, %Req.Response{status: status, body: body}}
  end
end
