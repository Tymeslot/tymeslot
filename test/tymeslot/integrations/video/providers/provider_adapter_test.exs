defmodule Tymeslot.Integrations.Video.Providers.ProviderAdapterTest do
  # Not async: the Zoom describes below dispatch through the real
  # VideoCircuitBreaker, an application-wide singleton keyed by provider, so
  # this module needs to run with nothing else concurrently tripping it.
  use ExUnit.Case, async: false
  @moduletag :integrations

  import Mox
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.Providers.JitsiProvider
  alias Tymeslot.Integrations.Video.Providers.MiroTalkProvider
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.ZoomOAuthHelperMock

  setup :verify_on_exit!

  setup do
    # `reset/1` is a cast, so it has to be flushed before the next test
    # starts: a following test that dispatches to Zoom would otherwise race
    # the reset this one left behind.
    on_exit(fn ->
      VideoCircuitBreaker.reset(:zoom)
      assert %{status: :closed, failure_count: 0} = VideoCircuitBreaker.status(:zoom)
    end)

    :ok
  end

  describe "extract_room_id/2" do
    # A custom video link is whatever the organiser pasted, so "/join/" paths
    # (Whereby, Jitsi, Daily) are common; the id the custom provider mints for
    # such a link is the digest it derives from the whole URL, not the last
    # path segment.
    @colliding_url "https://whereby.com/join/team-standup"
    @custom_room_id "176c39fdfe37cdea"

    test "parses by the named provider's rules" do
      assert ProviderAdapter.extract_room_id(@colliding_url, :custom) == @custom_room_id
      assert ProviderAdapter.extract_room_id(@colliding_url, :mirotalk) == "team-standup"
    end

    test "accepts the string form a persisted integration carries" do
      assert ProviderAdapter.extract_room_id(@colliding_url, "custom") == @custom_room_id
    end

    test "returns nil for an unknown provider and for a non-binary URL" do
      assert ProviderAdapter.extract_room_id(@colliding_url, :nextcloud_talk) == nil
      assert ProviderAdapter.extract_room_id(nil, :custom) == nil
    end
  end

  describe "create_meeting_room/2" do
    test "successfully creates room and handles event" do
      config = %{api_key: "key", base_url: "https://mirotalk.test"}

      # A single MiroTalk API call: `validate_config/1` runs first but is a
      # structural check, so creating a room costs the customer's server one
      # request rather than a pre-flight connection test plus the real one.
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"meeting" => "https://mirotalk.test/room123"})
         }}
      end)

      assert {:ok, context} = ProviderAdapter.create_meeting_room(:mirotalk, config)
      assert context.provider_type == :mirotalk
      assert context.provider_module == MiroTalkProvider
    end

    test "returns error for unknown provider" do
      assert {:error, "Unknown video provider type: unknown"} =
               ProviderAdapter.create_meeting_room(:unknown, %{})
    end
  end

  describe "update_meeting_room/3" do
    test "dispatches to provider callback and propagates return value (Zoom)" do
      config = %{
        oauth_scope: "meeting:write:meeting meeting:update:meeting",
        access_token: "test-token",
        refresh_token: "test-refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        meeting_start_time: DateTime.add(DateTime.utc_now(), 3600, :second),
        meeting_end_time: DateTime.add(DateTime.utc_now(), 5400, :second)
      }

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ProviderAdapter.update_meeting_room(:zoom, "987654321", config)
    end

    test "returns :ok via no-op fallback for providers without the callback (MiroTalk)" do
      assert :ok = ProviderAdapter.update_meeting_room(:mirotalk, "room123", %{})
    end

    test "returns error for unknown provider" do
      assert {:error, _reason} = ProviderAdapter.update_meeting_room(:unknown, "room123", %{})
    end
  end

  describe "delete_meeting_room/3" do
    test "dispatches to provider callback and propagates return value (Zoom)" do
      config = %{
        oauth_scope: "meeting:write:meeting meeting:delete:meeting",
        access_token: "test-token",
        refresh_token: "test-refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = ProviderAdapter.delete_meeting_room(:zoom, "987654321", config)
    end

    # Each provider words "not found" its own way; a delete only needs the
    # room gone, so callers never handle it.
    test "counts a room the provider no longer has as deleted" do
      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert :ok =
               ProviderAdapter.delete_meeting_room(:nextcloud_talk, "abc123xy", %{
                 base_url: "https://cloud.example.com",
                 client_id: "organiser",
                 client_secret: "Abcde-Fghij-Klmno-Pqrst-Uvwxy",
                 needs_reauth: false
               })
    end

    test "returns :ok via no-op fallback for providers without the callback (MiroTalk)" do
      assert :ok = ProviderAdapter.delete_meeting_room(:mirotalk, "room123", %{})
    end

    test "returns error for unknown provider" do
      assert {:error, _reason} = ProviderAdapter.delete_meeting_room(:unknown, "room123", %{})
    end
  end

  describe "shared_join_url/2" do
    # The point of the default: a provider whose join links are plain room
    # addresses keeps handing out the room URL for a guest without having to
    # opt out of anything, so adding the callback changed nobody but Jitsi.
    test "answers with the room's own URL for a provider that does not implement it" do
      Code.ensure_loaded!(MiroTalkProvider)
      refute function_exported?(MiroTalkProvider, :shared_join_url, 2)

      context = %MeetingContext{
        provider_type: :mirotalk,
        provider_module: MiroTalkProvider,
        room_data: %RoomData{
          room_id: "r1",
          meeting_url: "https://video.example.com/join/r1",
          provider_data: %{},
          provider_config: %{}
        }
      }

      assert ProviderAdapter.shared_join_url(context, DateTime.utc_now()) ==
               {:ok, "https://video.example.com/join/r1"}
    end

    test "dispatches to a provider that does implement it" do
      secret = "adapter-shared-secret-of-at-least-32-bytes"

      context = %MeetingContext{
        provider_type: :jitsi,
        provider_module: JitsiProvider,
        room_data: %RoomData{
          room_id: "0123456789abcdef",
          meeting_url: "https://meet.example.com/0123456789abcdef",
          provider_data: %{},
          provider_config: %{
            base_url: "https://meet.example.com",
            client_id: "tymeslot",
            client_secret: secret
          }
        }
      }

      assert {:ok, url} = ProviderAdapter.shared_join_url(context, DateTime.utc_now())
      assert url =~ "jwt="
    end
  end
end
