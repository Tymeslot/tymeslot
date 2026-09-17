defmodule Tymeslot.Integrations.VideoTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.IntegrationHealthWorker
  alias Tymeslot.Workers.VideoIntegrationDisconnectWorker
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  describe "handle_reauth_required/2" do
    test "flags the integration and emails its owner on the false → true transition" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, needs_reauth: false)

      assert {:discard, _reason} = Video.handle_reauth_required(integration)

      reloaded = Repo.reload!(integration)
      assert reloaded.needs_reauth

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_reauth_notification",
          "user_id" => user.id,
          "integration_id" => integration.id,
          "integration_type" => "video"
        }
      )
    end

    test "does not email again for an integration already flagged" do
      integration = insert(:video_integration, needs_reauth: true, sync_error: "Old reason.")

      assert {:discard, _reason} = Video.handle_reauth_required(integration)

      refute_enqueued(worker: EmailWorker)
    end
  end

  describe "list_integrations/1" do
    test "lists all integrations for a user" do
      user = insert(:user)
      _i1 = insert(:video_integration, user: user, name: "I1", provider: "mirotalk")
      _i2 = insert(:video_integration, user: user, name: "I2", provider: "custom")

      integrations = Video.list_integrations(user.id)
      assert length(integrations) == 2
    end
  end

  describe "create_integration/3" do
    test "creates mirotalk integration after testing connection" do
      user = insert(:user)

      attrs = %{
        "name" => "My MiroTalk",
        "base_url" => "https://mirotalk.test",
        "api_key" => "test-key"
      }

      # Adding an integration still tests the connection, but exactly once.
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200}}
      end)

      assert {:ok, integration} = Video.create_integration(user.id, :mirotalk, attrs)
      assert integration.provider == "mirotalk"
      assert integration.name == "My MiroTalk"
    end

    test "returns error if mirotalk connection test fails" do
      user = insert(:user)

      attrs = %{
        "name" => "Bad MiroTalk",
        "base_url" => "https://mirotalk.test",
        "api_key" => "bad-key"
      }

      # Mock connection failure
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: "Unauthorized"}}
      end)

      assert {:error, {:invalid_api_key, "Invalid API key - Authentication failed"}} =
               Video.create_integration(user.id, :mirotalk, attrs)
    end

    test "safely handles non-existing atom keys in attrs" do
      user = insert(:user)

      attrs = %{
        "name" => "Safe Integration",
        "custom_meeting_url" => "https://meet.jit.si/my-room",
        "some_crazy_key_that_does_not_exist_as_atom_12345" => "value"
      }

      # Should not crash and successfully create integration (ignoring the bad key)
      assert {:ok, integration} = Video.create_integration(user.id, :custom, attrs)
      assert integration.name == "Safe Integration"
    end
  end

  describe "delete_integration/3" do
    test "deletes user's integration" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      assert {:ok, :deleted} = Video.delete_integration(user.id, integration.id)
      assert Video.list_integrations(user.id) == []
    end

    test "leaves provider rooms alone by default" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      assert {:ok, :deleted} = Video.delete_integration(user.id, integration.id)

      # Upcoming bookings' join URLs are already in attendees' calendar invites,
      # so disconnecting alone must not break them.
      refute_enqueued(worker: VideoIntegrationDisconnectWorker)
    end

    test "soft-deletes and schedules the drain when room cleanup is requested" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      assert {:ok, :cleanup_scheduled} =
               Video.delete_integration(user.id, integration.id, delete_rooms: true)

      assert_enqueued(
        worker: VideoIntegrationDisconnectWorker,
        args: %{"integration_id" => integration.id}
      )

      # Gone from the user's view immediately, but still present so the job can
      # authenticate against the provider.
      assert Video.list_integrations(user.id) == []
      assert {:ok, pending} = VideoIntegrationQueries.get(integration.id)
      assert pending.deleted_at
      refute pending.is_active
    end
  end

  describe "rooms_deleted_on_disconnect/2" do
    setup do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "zoom")
      %{user: user, integration: integration}
    end

    # Each booking gets its own slot: confirmed bookings share a per-organiser
    # uniqueness constraint on start time.
    defp room_booking(user, integration, hours_ahead, attrs \\ %{}) do
      insert_meeting_for_user(
        user,
        Map.merge(
          %{
            start_offset: hours_ahead * 3_600,
            video_integration_id: integration.id,
            video_provider: "zoom",
            video_room_id: "room-#{hours_ahead}"
          },
          attrs
        )
      )
    end

    test "counts the owner's upcoming bookings holding a room from the integration",
         %{user: user, integration: integration} do
      room_booking(user, integration, 24)
      room_booking(user, integration, 48)

      assert %{scope: :upcoming, count: 2} =
               Video.rooms_deleted_on_disconnect(user.id, integration.id)
    end

    test "counts exactly the bookings the room cleanup drains",
         %{user: user, integration: integration} do
      room_booking(user, integration, 24)
      room_booking(user, integration, -24)
      room_booking(user, integration, 72, %{status: "cancelled"})

      drained =
        MeetingListQueries.list_with_video_room_for_integration(
          integration.id,
          :upcoming,
          DateTime.utc_now(),
          500
        )

      assert length(drained) == 1

      assert %{count: count} = Video.rooms_deleted_on_disconnect(user.id, integration.id)
      assert count == length(drained)
    end

    test "is 0 for an integration the user does not own", %{integration: integration} do
      owner = Repo.preload(integration, :user).user
      room_booking(owner, integration, 24)
      stranger = insert(:user)

      assert %{count: 0} = Video.rooms_deleted_on_disconnect(stranger.id, integration.id)
    end

    test "leaves out past, cancelled, room-less and voided bookings, and other integrations",
         %{user: user, integration: integration} do
      other = insert(:video_integration, user: user, provider: "zoom")

      room_booking(user, integration, -24)
      room_booking(user, integration, 24, %{status: "cancelled"})
      room_booking(user, integration, 48, %{video_room_id: nil})
      room_booking(user, integration, 72, %{reschedule_requested_at: DateTime.utc_now()})
      room_booking(user, other, 96)
      room_booking(user, integration, 120)

      assert %{count: 1} = Video.rooms_deleted_on_disconnect(user.id, integration.id)
    end

    test "counts a Talk integration's past rooms too, which stay on the organiser's server",
         %{user: user} do
      talk = insert(:video_integration, user: user, provider: "nextcloud_talk")

      room_booking(user, talk, -24, %{video_provider: "nextcloud_talk"})
      room_booking(user, talk, 24, %{video_provider: "nextcloud_talk"})

      assert %{scope: :all, count: 2} = Video.rooms_deleted_on_disconnect(user.id, talk.id)
    end
  end

  describe "toggle_integration/2" do
    test "toggles active status" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      {:ok, updated} = Video.toggle_integration(user.id, integration.id)
      refute updated.is_active

      {:ok, updated2} = Video.toggle_integration(user.id, integration.id)
      assert updated2.is_active
    end

    test "enqueues an IntegrationHealthWorker probe when reactivating (inactive → active)" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: false)

      assert {:ok, updated} = Video.toggle_integration(user.id, integration.id)
      assert updated.is_active

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "video", "integration_id" => integration.id}
      )
    end

    test "does NOT enqueue a probe when deactivating (active → inactive)" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      assert {:ok, updated} = Video.toggle_integration(user.id, integration.id)
      refute updated.is_active

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "video", "integration_id" => integration.id}
      )
    end
  end

  describe "update_integration/3" do
    test "returns the updated integration on success" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, name: "Old Name")

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{name: "New Name"})

      assert updated.name == "New Name"
    end

    test "enqueues an IntegrationHealthWorker probe and resets the health row when credential fields are present" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      # Seed an unhealthy row so we can verify the reset fires.
      %IntegrationHealthStateSchema{}
      |> IntegrationHealthStateSchema.changeset(%{
        integration_type: "video",
        integration_id: integration.id,
        user_id: user.id,
        status: "unhealthy",
        failures: 5,
        consecutive_hard_failures: 5,
        successes: 0,
        backoff_ms: :timer.hours(1)
      })
      |> Repo.insert!()

      assert {:ok, _updated} =
               Video.update_integration(user.id, integration.id, %{
                 api_key: "new-key"
               })

      # Health row is reset to a healthy baseline.
      {:ok, row} = IntegrationHealthStateQueries.get(:video, integration.id)
      assert row.status == "healthy"
      assert row.failures == 0

      # Immediate verification probe is enqueued.
      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "video", "integration_id" => integration.id}
      )
    end

    test "does NOT enqueue a probe when no credential fields are present" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, name: "Before")

      assert {:ok, _updated} =
               Video.update_integration(user.id, integration.id, %{name: "After"})

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "video", "integration_id" => integration.id}
      )
    end

    # Only a reconnect proven against the provider re-sends reschedules: a
    # credential that merely replaces the stored one may still be refused.
    test "an unproven credential that clears the reconnect flag queues no room update" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "zoom", needs_reauth: true)
      start_time = DateTime.add(DateTime.utc_now(:second), 2, :day)

      insert(:meeting,
        organizer_user_id: user.id,
        video_integration_id: integration.id,
        video_room_id: "zoom-room",
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute)
      )

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{api_key: "replaced-key"})

      refute updated.needs_reauth
      refute_enqueued(worker: VideoSyncWorker)
    end

    test "returns {:error, :not_found} for an integration belonging to another user" do
      user = insert(:user)
      other = insert(:user)
      integration = insert(:video_integration, user: other)

      assert {:error, :not_found} =
               Video.update_integration(user.id, integration.id, %{name: "Stolen"})
    end
  end

  describe "oauth_authorization_url/2" do
    test "generates google meet auth URL" do
      user = insert(:user)

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _uid, _uri, _scopes, _opts ->
        "https://accounts.google.com/o/oauth2/v2/auth?client_id=123"
      end)

      assert {:ok, url} = Video.oauth_authorization_url(user.id, :google_meet)
      assert String.contains?(url, "accounts.google.com")
    end

    test "generates teams auth URL" do
      user = insert(:user)

      expect(Tymeslot.TeamsOAuthHelperMock, :authorization_url, fn _uid, _uri, _opts ->
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=456"
      end)

      assert {:ok, url} = Video.oauth_authorization_url(user.id, :teams)
      assert String.contains?(url, "login.microsoftonline.com")
    end

    test "generates zoom auth URL" do
      user = insert(:user)

      expect(Tymeslot.ZoomOAuthHelperMock, :authorization_url, fn _uid, _uri, _opts ->
        "https://zoom.us/oauth/authorize?client_id=test-client-id&response_type=code"
      end)

      assert {:ok, url} = Video.oauth_authorization_url(user.id, :zoom)
      assert String.contains?(url, "zoom.us")
    end

    test "returns error when zoom oauth helper raises" do
      user = insert(:user)

      expect(Tymeslot.ZoomOAuthHelperMock, :authorization_url, fn _uid, _uri, _opts ->
        raise RuntimeError, "Zoom Client ID not configured"
      end)

      assert {:error, message} = Video.oauth_authorization_url(user.id, :zoom)
      assert String.contains?(message, "Zoom")
    end

    test "returns error for non-oauth provider" do
      assert {:error, _reason} = Video.oauth_authorization_url(1, :mirotalk)
    end
  end

  # These paths were previously untestable: the reconnect call passes options
  # on an arity the OAuth behaviours did not declare, so the Mox doubles could
  # not answer it. The behaviours now declare it.
  describe "oauth_reconnect_url/2" do
    test "targets the connected Google account with scopes and login hint" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          provider_account_email: "someone@example.com"
        )

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _uid, _uri, scopes, opts ->
        assert scopes == [:calendar, :meet]
        assert Keyword.get(opts, :integration_id) == integration.id
        assert Keyword.get(opts, :login_hint) == "someone@example.com"
        "https://accounts.google.com/o/oauth2/v2/auth?login_hint=someone@example.com"
      end)

      assert {:ok, url} = Video.oauth_reconnect_url(user.id, integration)
      assert String.contains?(url, "accounts.google.com")
    end

    test "targets the connected Teams account" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "teams",
          provider_account_email: "someone@example.com"
        )

      expect(Tymeslot.TeamsOAuthHelperMock, :authorization_url, fn _uid, _uri, opts ->
        assert Keyword.get(opts, :integration_id) == integration.id
        assert Keyword.get(opts, :login_hint) == "someone@example.com"
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
      end)

      assert {:ok, url} = Video.oauth_reconnect_url(user.id, integration)
      assert String.contains?(url, "login.microsoftonline.com")
    end

    test "targets the connected Zoom account" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "zoom",
          provider_account_email: "someone@example.com"
        )

      expect(Tymeslot.ZoomOAuthHelperMock, :authorization_url, fn _uid, _uri, opts ->
        assert Keyword.get(opts, :integration_id) == integration.id
        assert Keyword.get(opts, :login_hint) == "someone@example.com"
        "https://zoom.us/oauth/authorize?client_id=test-client-id"
      end)

      assert {:ok, url} = Video.oauth_reconnect_url(user.id, integration)
      assert String.contains?(url, "zoom.us")
    end

    test "reports a misconfiguration rather than raising" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "zoom")

      expect(Tymeslot.ZoomOAuthHelperMock, :authorization_url, fn _uid, _uri, _opts ->
        raise RuntimeError, "Zoom Client Secret not configured"
      end)

      assert {:error, message} = Video.oauth_reconnect_url(user.id, integration)
      assert message =~ "ZOOM_CLIENT_SECRET"
    end

    test "refuses a provider that does not support OAuth" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "mirotalk")

      assert {:error, _reason} = Video.oauth_reconnect_url(user.id, integration)
    end
  end
end
