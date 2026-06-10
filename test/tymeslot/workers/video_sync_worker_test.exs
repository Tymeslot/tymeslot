defmodule Tymeslot.Workers.VideoSyncWorkerTest do
  @moduledoc """
  Drives the supervised video-room sync worker used by reschedule (update) and
  cancellation (delete). Covers the happy path, the transient-failure retry
  path, the idempotent already-gone path, and the no-room discard.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :workers

  import Mox
  import Tymeslot.MeetingTestHelpers

  alias Ecto.UUID
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.ZoomOAuthHelperMock

  setup :verify_on_exit!

  describe "enqueue/2" do
    test "inserts an update job" do
      assert {:ok, :scheduled} = VideoSyncWorker.enqueue("meeting-1", "update")

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => "meeting-1", "action" => "update"}
      )
    end

    test "deduplicates within the uniqueness window" do
      assert {:ok, :scheduled} = VideoSyncWorker.enqueue("meeting-2", "delete")
      assert {:ok, :already_scheduled} = VideoSyncWorker.enqueue("meeting-2", "delete")
    end
  end

  describe "perform/1 — update" do
    test "PATCHes the Zoom meeting with the meeting's current times" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "111",
          title: "Strategy sync"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, url, body, _headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/111"
        decoded = Jason.decode!(body)
        assert decoded["topic"] == "Strategy sync"
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})
    end

    test "returns an error so Oban retries when Zoom responds transiently" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "222"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 503, body: ~s({"code":500,"message":"server error"})}}
      end)

      assert {:error, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})
    end
  end

  describe "perform/1 — delete" do
    test "DELETEs the Zoom meeting" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "333"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/333"
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})
    end

    test "treats a 404 as already-synced success" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "gone"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})
    end
  end

  describe "perform/1 — guards" do
    test "discards when the meeting carries no video room" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: nil,
          video_room_id: nil
        })

      assert {:discard, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})
    end

    test "discards when the meeting no longer exists" do
      assert {:discard, _reason} =
               perform_job(VideoSyncWorker, %{
                 "meeting_id" => UUID.generate(),
                 "action" => "update"
               })
    end
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
      oauth_scope: "meeting:write:meeting",
      provider_account_id: nil
    )
  end
end
