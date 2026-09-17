defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalkReauthTest do
  @moduledoc """
  A refused app password flags the saved integration for reconnection, which
  is what stops every later call from spending another login attempt against
  the server's brute-force protection.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    integration =
      insert(:video_integration,
        user: user,
        provider: "nextcloud_talk",
        base_url: "https://cloud.example.com",
        client_id_encrypted: Encryption.encrypt("organiser"),
        client_secret_encrypted: Encryption.encrypt("Revoked-App-Password"),
        provider_account_id: "https://cloud.example.com||organiser"
      )

    decrypted = VideoIntegrationSchema.decrypt_credentials(integration)

    %{
      integration: integration,
      config: NextcloudTalkProvider.build_config(integration, decrypted, meeting_id: "m-1")
    }
  end

  test "a refused app password during room creation flags the integration", %{
    integration: integration,
    config: config
  } do
    expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 401, body: ""}}
    end)

    config = Map.put(config, :event_details, %EventDetails{summary: "Intro call"})

    assert {:error, :unauthorized} = NextcloudTalkProvider.create_meeting_room(config)

    flagged = Repo.get!(VideoIntegrationSchema, integration.id)
    assert flagged.needs_reauth
    assert flagged.sync_error =~ "app password"
  end

  test "a refused app password during a connection test flags the integration", %{
    integration: integration,
    config: config
  } do
    expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 401, body: ""}}
    end)

    assert {:error, {:unauthorized, _message}} =
             NextcloudTalkProvider.perform_connection_test(config)

    assert Repo.get!(VideoIntegrationSchema, integration.id).needs_reauth
  end

  test "a throttled server leaves the integration unflagged", %{
    integration: integration,
    config: config
  } do
    expect(HTTPClientMock, :request, 2, fn _method, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 429, body: ""}}
    end)

    config = Map.put(config, :event_details, %EventDetails{summary: "Intro call"})

    assert {:error, :rate_limited} = NextcloudTalkProvider.create_meeting_room(config)

    assert {:error, {:unreachable, _message}} =
             NextcloudTalkProvider.perform_connection_test(config)

    refute Repo.get!(VideoIntegrationSchema, integration.id).needs_reauth
  end

  test "build_config/3 carries the flag the provider refuses on", %{integration: integration} do
    flagged = integration |> Changeset.change(needs_reauth: true) |> Repo.update!()
    decrypted = VideoIntegrationSchema.decrypt_credentials(flagged)

    config = NextcloudTalkProvider.build_config(flagged, decrypted, [])

    assert config.needs_reauth
    assert config.integration_id == flagged.id
    assert config.client_id == "organiser"
  end
end
