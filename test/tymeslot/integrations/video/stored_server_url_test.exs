defmodule Tymeslot.Integrations.Video.StoredServerUrlTest do
  @moduledoc """
  A rule for a self-hosted server's address applies to an address being
  saved. One stored before the rule keeps getting rooms: every room and every
  health probe checks the stored config again.
  """

  # Not async: the private-address switch is application config.
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Mox
  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.Rooms
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, :allow_private_ips_for_video, false)
    %{user: insert(:user)}
  end

  test "a MiroTalk address stored with a query string still gets rooms", %{user: user} do
    integration =
      insert(:video_integration,
        user: user,
        provider: "mirotalk",
        base_url: "https://mirotalk.example.com/?team=1",
        api_key_encrypted: Encryption.encrypt("test-key")
      )

    expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"meeting" => "https://mirotalk.example.com/room123"})
       }}
    end)

    assert {:ok, %{room_data: %{room_id: "https://mirotalk.example.com/room123"}}} =
             Rooms.create_meeting_room(user.id, integration_id: integration.id)
  end

  # Saved while the operator allowed private video addresses.
  test "a local Jitsi server with token authentication still gets rooms once private addresses are no longer allowed",
       %{user: user} do
    integration =
      insert(:video_integration,
        user: user,
        provider: "jitsi",
        base_url: "http://localhost:8443",
        client_id_encrypted: Encryption.encrypt("tymeslot"),
        client_secret_encrypted: Encryption.encrypt("test-secret-value-at-least-32-chars-long")
      )

    assert {:ok, %{room_data: %{meeting_url: "http://localhost:8443/" <> _room}}} =
             Rooms.create_meeting_room(user.id,
               integration_id: integration.id,
               meeting_id: "booking-1"
             )
  end
end
