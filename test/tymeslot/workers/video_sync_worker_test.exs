defmodule Tymeslot.Workers.VideoSyncWorkerTest do
  @moduledoc """
  Drives the supervised video-room sync worker used by reschedule (update) and
  cancellation (delete). Covers the happy path, the transient-failure retry
  path, the idempotent already-gone path, and the no-room discard.
  """

  # Not async: several tests here induce real Zoom video-breaker failures
  # (VideoCircuitBreaker is an application-wide singleton keyed by provider),
  # so this module needs the DataCase-wide breaker reset that only runs
  # between non-async modules.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :workers

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.MeetingTestHelpers

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Repo
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
      # A real 5xx counts as a failure against the shared, VM-wide zoom
      # circuit breaker (`BreakerOutcome.classify/1`). Reset it around this
      # test so a single transient-failure assertion here cannot nudge a
      # concurrently running test elsewhere closer to tripping it for real.
      on_exit(fn -> VideoCircuitBreaker.reset(:zoom) end)

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

    test "discards instead of retrying when the grant lacks the update scope" do
      %{user: user} = create_user_with_profile()

      integration =
        insert_zoom_integration(user)
        |> Changeset.change(%{
          oauth_scope: "meeting:write:meeting meeting:delete:meeting"
        })
        |> Repo.update!()

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "444"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      # Retrying cannot widen a grant, so the job must not burn its budget and
      # page an admin. Nor is the user flagged: Tymeslot does not request
      # `meeting:update:meeting`, so reconnecting would change nothing.
      assert {:discard, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})

      refute Repo.reload!(integration).needs_reauth
    end

    test "discards instead of retrying when Zoom rejects the PATCH with 4711" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "555"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 400,
           body:
             Jason.encode!(%{
               "code" => 4711,
               "message" =>
                 "Invalid access token, does not contain scopes:" <>
                   "[meeting:update:meeting:admin, meeting:update:meeting]."
             })
         }}
      end)

      assert {:discard, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})

      refute Repo.reload!(integration).needs_reauth
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

    test "discards instead of retrying when the grant lacks the delete scope" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "333"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 400,
           body:
             Jason.encode!(%{
               "code" => 4711,
               "message" =>
                 "Invalid access token, does not contain scopes:[meeting:delete:meeting]."
             })
         }}
      end)

      # Re-consent is the only fix, so the job must not burn its retry budget.
      assert {:discard, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})
    end
  end

  describe "perform/1 — disconnected integration" do
    test "deletes through a reconnected integration when the original link is gone" do
      %{user: user} = create_user_with_profile()
      # The user disconnected Zoom and reconnected it: a fresh integration row
      # with valid credentials for the same provider.
      insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: nil,
          video_provider: "zoom",
          video_room_id: "86360699337"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/86360699337"
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})
    end

    test "updates through a reconnected integration on reschedule" do
      %{user: user} = create_user_with_profile()
      insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: nil,
          video_provider: "zoom",
          video_room_id: "444"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, url, _body, _headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/444"
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})
    end

    test "warns and discards when no integration can reach the room" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: nil,
          video_provider: "zoom",
          video_room_id: "86360699337"
        })

      log =
        capture_log(fn ->
          assert {:discard, _reason} =
                   perform_job(VideoSyncWorker, %{
                     "meeting_id" => meeting.id,
                     "action" => "delete"
                   })
        end)

      # Silence here is the original defect: an unreachable room must be visible.
      # The meeting id, provider and room id ride along as Logger metadata and
      # reach production logs via the JSON formatter's :all_except setting; the
      # test formatter whitelists only a few keys, so :reason is what is
      # assertable here.
      assert log =~ "no video integration can reach it"
      assert log =~ "reason=no_active_integration"
    end
  end

  describe "perform/1 — room bookkeeping" do
    test "clears the room id once the provider delete succeeds" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_provider: "zoom",
          video_room_id: "4242",
          video_room_enabled: true
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})

      # "cancelled and still holding a room id" has to mean "not cleaned up yet"
      # or the orphan scan can never converge.
      reloaded = Repo.reload!(meeting)
      assert reloaded.video_room_id == nil
      refute reloaded.video_room_enabled
    end

    test "keeps the room id after an update so reschedules stay syncable" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_provider: "zoom",
          video_room_id: "5150"
        })

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})

      assert Repo.reload!(meeting).video_room_id == "5150"
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
      oauth_scope: "meeting:write:meeting meeting:update:meeting meeting:delete:meeting",
      provider_account_id: nil
    )
  end
end
