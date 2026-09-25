defmodule Tymeslot.Workers.VideoSyncWorkerTest do
  @moduledoc """
  Drives the supervised video-room sync worker used by reschedule (update) and
  cancellation (delete). Releasing a room a moved meeting left behind is in
  `Tymeslot.Workers.VideoSyncWorkerReleaseTest`. Covers the happy path, the transient-failure retry
  path, the idempotent already-gone path, and the no-room discard.
  """

  # Not async: several tests here induce real Zoom video-breaker failures
  # (VideoCircuitBreaker is an application-wide singleton keyed by provider),
  # so this module needs the DataCase-wide breaker reset that only runs
  # between non-async modules.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :workers

  import Mox
  import Tymeslot.MeetingTestHelpers

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LogCapture
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
          title: "Strategy sync",
          summary: nil
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
      # page an admin. Reconnecting can, so the owner is flagged instead.
      assert {:discard, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})

      assert Repo.reload!(integration).needs_reauth
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

      assert Repo.reload!(integration).needs_reauth
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

      events =
        LogCapture.with_capture(fn ->
          assert {:discard, _reason} =
                   perform_job(VideoSyncWorker, %{
                     "meeting_id" => meeting.id,
                     "action" => "delete"
                   })

          LogCapture.drain()
        end)

      logged = Enum.map_join(events, "\n", &LogCapture.dump/1)

      # Silence here is the original defect: an unreachable room must be visible.
      # `LogCapture` sees the metadata the JSON formatter ships in production
      # and the test formatter's whitelist would drop.
      assert logged =~ "no video integration can reach it"
      assert logged =~ "reason: :no_active_integration"
      assert logged =~ "meeting_id: \"#{meeting.id}\""

      # The room the job could not reach is still identified, but by a
      # fingerprint: the id itself is the join link for a link-based provider,
      # and the meeting id already leads to the row that holds it. fdfa5bf3 is
      # the first eight hex characters of the SHA-256 of "86360699337".
      assert logged =~ "room_ref: \"fdfa5bf3\""
      refute logged =~ "86360699337"
    end
  end

  describe "perform/1 — room bookkeeping" do
    test "clears the room id and its join links once the provider delete succeeds" do
      %{user: user} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_provider: "zoom",
          video_room_id: "4242",
          video_room_enabled: true,
          organizer_video_url: "https://zoom.example.com/s/4242",
          attendee_video_url: "https://zoom.example.com/j/4242"
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

      # The room is gone, so the links into it are dead and go with it.
      assert reloaded.organizer_video_url == nil
      assert reloaded.attendee_video_url == nil
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

  describe "perform/1, refused credentials" do
    test "discards rather than retrying when the provider refuses the stored credentials" do
      %{meeting: meeting, integration: integration} = talk_meeting("refused.example.com")

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:discard, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})

      assert Repo.get!(VideoIntegrationSchema, integration.id).needs_reauth
      assert Repo.reload!(meeting).video_room_id == "abc123xy"
    end
  end

  describe "perform/1, refusals that repeat" do
    test "discards a deletion the server refuses, keeping the room id" do
      %{meeting: meeting} = talk_meeting("forbidden.example.com")

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: talk_refusal()}}
      end)

      assert {:discard, "Invalid configuration"} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})

      assert Repo.reload!(meeting).video_room_id == "abc123xy"
    end

    test "clears the room id when the owner marked the conversation to be preserved" do
      %{meeting: meeting} = talk_meeting("preserved.example.com")

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 403,
           body: Jason.encode!(%{"ocs" => %{"data" => %{"error" => "preserved"}}})
         }}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})

      assert Repo.reload!(meeting).video_room_id == nil
    end

    test "clears the room id when the conversation is already gone" do
      %{meeting: meeting} = talk_meeting("gone.example.com")

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})

      assert Repo.reload!(meeting).video_room_id == nil
    end
  end

  describe "perform/1, Nextcloud Talk reschedule" do
    test "renames the conversation to the name it was created with" do
      %{meeting: meeting} = talk_meeting("rename.example.com")

      meeting =
        meeting
        |> Changeset.change(title: "Intro call", summary: "  Quarterly review  ")
        |> Repo.update!()

      expect(HTTPClientMock, :request, fn :put, url, _body, _headers, _opts ->
        assert url =~ "/webinar/lobby"
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"ocs" => %{"data" => %{}}})}}
      end)

      expect(HTTPClientMock, :request, fn :put, _url, body, _headers, _opts ->
        assert Jason.decode!(body) == %{"roomName" => "Quarterly review"}
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"ocs" => %{"data" => []}})}}
      end)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})
    end
  end

  describe "perform/1, circuit open" do
    test "discards once the snooze budget for an open breaker is spent" do
      host = "breaker.example.com"
      on_exit(fn -> VideoCircuitBreaker.reset(:nextcloud_talk, host) end)

      %{meeting: meeting} = talk_meeting(host)
      trip_talk_breaker(host)

      args = %{"meeting_id" => meeting.id, "action" => "delete"}

      assert {:snooze, _seconds} = perform_job(VideoSyncWorker, args)

      assert {:discard, reason} =
               perform_job(VideoSyncWorker, args, meta: %{"snoozed" => 9})

      assert reason =~ "circuit breaker still open"
      assert Repo.reload!(meeting).video_room_id == "abc123xy"
    end
  end

  describe "perform/1, rate limited" do
    test "snoozes on an interval that grows with each execution" do
      %{meeting: meeting} = talk_meeting("throttled.example.com")

      expect(HTTPClientMock, :request, 2, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: ""}}
      end)

      args = %{"meeting_id" => meeting.id, "action" => "delete"}

      assert {:snooze, 60} = perform_job(VideoSyncWorker, args)
      assert {:snooze, 180} = perform_job(VideoSyncWorker, args, meta: %{"snoozed" => 2})
      assert Repo.reload!(meeting).video_room_id == "abc123xy"
    end

    test "falls back to the ordinary retries once the snooze budget is spent" do
      %{meeting: meeting} = talk_meeting("still-throttled.example.com")

      expect(HTTPClientMock, :request, fn :put, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: ""}}
      end)

      assert {:error, :rate_limited} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"},
                 meta: %{"snoozed" => 9}
               )
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

  defp trip_talk_breaker(host) do
    %{failure_threshold: threshold} = VideoCircuitBreaker.get_config(:nextcloud_talk)

    Enum.each(1..threshold, fn _i ->
      VideoCircuitBreaker.call_with_host(:nextcloud_talk, host, fn ->
        {:provider_error, :simulated_outage}
      end)
    end)

    assert %{status: :open} = VideoCircuitBreaker.status(:nextcloud_talk, host)
  end

  # Each test gets its own server, so the failures one test induces never open
  # the per-host breaker another test calls through.
  defp talk_meeting(host) do
    %{user: user} = create_user_with_profile()
    base_url = "https://" <> host

    integration =
      insert(:video_integration,
        user: user,
        provider: "nextcloud_talk",
        base_url: base_url,
        client_id_encrypted: Encryption.encrypt("organiser"),
        client_secret_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy"),
        provider_account_id: base_url <> "||organiser"
      )

    meeting =
      insert_meeting_for_user(user, %{
        video_integration_id: integration.id,
        video_provider: "nextcloud_talk",
        video_room_id: "abc123xy"
      })

    %{meeting: meeting, integration: integration}
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

  # A refusal Talk itself worded: a 403 whose body is not the OCS envelope
  # comes from something in front of Nextcloud, which the client reports as an
  # HTTP error instead.
  defp talk_refusal do
    Jason.encode!(%{
      "ocs" => %{
        "meta" => %{"status" => "failure", "statuscode" => 403, "message" => ""},
        "data" => %{"error" => "permissions"}
      }
    })
  end
end
