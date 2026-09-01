defmodule Tymeslot.Workers.VideoIntegrationDisconnectWorkerTest do
  @moduledoc """
  Drives the worker that deletes provider-side rooms for a disconnected video
  integration and then purges the soft-deleted row. Covers the happy path, the
  retry path, the give-up path, and the undecryptable-credentials path.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers

  import Mox
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoIntegrationDisconnectWorker
  alias Tymeslot.ZoomOAuthHelperMock

  setup :verify_on_exit!

  test "deletes each upcoming room, clears the booking, and purges the row" do
    %{user: user} = create_user_with_profile()
    integration = insert_zoom_integration(user)

    meeting =
      insert_meeting_for_user(user, %{
        video_integration_id: integration.id,
        video_provider: "zoom",
        video_room_id: "777",
        video_room_enabled: true
      })

    {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

    stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
      assert url == "https://api.zoom.us/v2/meetings/777"
      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    assert :ok =
             perform_job(VideoIntegrationDisconnectWorker, %{"integration_id" => integration.id})

    reloaded = Repo.reload!(meeting)
    assert reloaded.video_room_id == nil
    refute reloaded.video_room_enabled
    assert reloaded.organizer_video_url == nil
    assert reloaded.attendee_video_url == nil

    # The attendee's invite must stop advertising a URL that no longer works.
    assert_enqueued(
      worker: Tymeslot.Workers.CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => meeting.id}
    )

    assert {:error, :not_found} = VideoIntegrationQueries.get(integration.id)
  end

  test "leaves past bookings alone" do
    %{user: user} = create_user_with_profile()
    integration = insert_zoom_integration(user)

    past =
      insert_meeting_for_user(user, %{
        start_offset: -7200,
        duration: 3600,
        video_integration_id: integration.id,
        video_provider: "zoom",
        video_room_id: "history"
      })

    {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

    # No HTTP expectation: the provider must not be contacted at all.
    assert :ok =
             perform_job(VideoIntegrationDisconnectWorker, %{"integration_id" => integration.id})

    assert Repo.reload!(past).video_room_id == "history"
    assert {:error, :not_found} = VideoIntegrationQueries.get(integration.id)
  end

  test "retries and keeps the row when the provider call fails" do
    %{user: user} = create_user_with_profile()
    integration = insert_zoom_integration(user)

    insert_meeting_for_user(user, %{
      video_integration_id: integration.id,
      video_provider: "zoom",
      video_room_id: "888"
    })

    {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

    stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
      {:error, :timeout}
    end)

    assert {:error, _reason} =
             perform_job(VideoIntegrationDisconnectWorker, %{"integration_id" => integration.id})

    # The credentials must survive so the retry can authenticate.
    assert {:ok, _still_there} = VideoIntegrationQueries.get(integration.id)
  end

  test "purges the row on the final attempt even if a room could not be deleted" do
    %{user: user} = create_user_with_profile()
    integration = insert_zoom_integration(user)

    insert_meeting_for_user(user, %{
      video_integration_id: integration.id,
      video_provider: "zoom",
      video_room_id: "999"
    })

    {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

    stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
      {:error, :timeout}
    end)

    # Stranding the user's OAuth credentials for ever is worse than leaving a
    # room the provider will not delete.
    assert :ok =
             perform_job(
               VideoIntegrationDisconnectWorker,
               %{"integration_id" => integration.id},
               attempt: 5
             )

    assert {:error, :not_found} = VideoIntegrationQueries.get(integration.id)
  end

  test "discards when the integration is already gone" do
    assert {:discard, _reason} =
             perform_job(VideoIntegrationDisconnectWorker, %{"integration_id" => 999_999})
  end

  test "skips the sweep entirely when the integration was reconnected before this attempt ran" do
    %{user: user} = create_user_with_profile()
    integration = insert_zoom_integration(user)

    meeting =
      insert_meeting_for_user(user, %{
        video_integration_id: integration.id,
        video_provider: "zoom",
        video_room_id: "reconnected-before-run"
      })

    {:ok, soft} = VideoIntegrationQueries.soft_delete(integration)
    {:ok, _reconnected} = VideoIntegrationQueries.update_credentials(soft, %{is_active: true})

    # No HTTP expectation: draining a reconnected integration's rooms is
    # exactly the bug being guarded against, so the provider must not be
    # contacted at all.
    assert :ok =
             perform_job(VideoIntegrationDisconnectWorker, %{"integration_id" => integration.id})

    assert Repo.reload!(meeting).video_room_id == "reconnected-before-run"
    assert {:ok, still_there} = VideoIntegrationQueries.get(integration.id)
    assert still_there.is_active
  end

  test "keeps a reconnect that lands mid-drain, even though the purge acted on a stale read" do
    %{user: user} = create_user_with_profile()
    integration = insert_zoom_integration(user)

    meeting =
      insert_meeting_for_user(user, %{
        video_integration_id: integration.id,
        video_provider: "zoom",
        video_room_id: "777"
      })

    {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

    stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    # The reconnect commits while the provider call for the only room in this
    # batch is in flight — after `perform/1`'s up-front guard already passed,
    # and before `purge/3` runs.
    expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
      {:ok, fetched} = VideoIntegrationQueries.get(integration.id)

      {:ok, _reconnected} =
        VideoIntegrationQueries.update_credentials(fetched, %{is_active: true})

      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    assert :ok =
             perform_job(VideoIntegrationDisconnectWorker, %{"integration_id" => integration.id})

    # The room delete itself still happened (it raced ahead of the reconnect),
    # but the reconnected row must not be purged out from under the user.
    refute Repo.reload!(meeting).video_room_id
    assert {:ok, still_there} = VideoIntegrationQueries.get(integration.id)
    assert still_there.is_active
  end

  defp insert_zoom_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Zoom",
      provider: "zoom",
      base_url: nil,
      api_key_encrypted: nil,
      tenant_id_encrypted: nil,
      client_id_encrypted: nil,
      client_secret_encrypted: nil,
      teams_user_id_encrypted: nil,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "meeting:write:meeting meeting:delete:meeting",
      provider_account_id: nil
    )
  end
end
