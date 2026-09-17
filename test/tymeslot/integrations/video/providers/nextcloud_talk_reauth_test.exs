defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalkReauthTest do
  @moduledoc """
  A refused app password flags the saved integration for reconnection, which
  is what stops every later call from spending another login attempt against
  the server's brute-force protection.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.EmailWorker

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

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_integration_reauth_notification",
        "user_id" => integration.user_id,
        "integration_id" => integration.id,
        "integration_type" => "video"
      }
    )
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

  test "a refused app password during a cancellation flags the integration", %{
    integration: integration,
    config: config
  } do
    expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 401, body: ""}}
    end)

    assert {:error, :unauthorized} = NextcloudTalkProvider.delete_meeting_room("abc123xy", config)
    assert Repo.get!(VideoIntegrationSchema, integration.id).needs_reauth
  end

  test "a refused app password during a reschedule flags the integration and stops there", %{
    integration: integration,
    config: config
  } do
    # One request only: the rename must not spend a second login attempt.
    expect(HTTPClientMock, :request, fn :put, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 401, body: ""}}
    end)

    config =
      Map.merge(config, %{meeting_start_time: ~U[2026-10-08 09:30:00Z], meeting_topic: "Moved"})

    assert {:error, :unauthorized} = NextcloudTalkProvider.update_meeting_room("abc123xy", config)
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
    refute_enqueued(worker: EmailWorker)
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
