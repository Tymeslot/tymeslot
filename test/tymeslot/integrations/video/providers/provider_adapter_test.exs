defmodule Tymeslot.Integrations.Video.Providers.ProviderAdapterTest do
  # Not async: the Zoom describes below dispatch through the real
  # VideoCircuitBreaker, an application-wide singleton keyed by provider, so
  # this module needs to run with nothing else concurrently tripping it.
  use ExUnit.Case, async: false
  @moduletag :integrations

  import Mox
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Integrations.Video.Providers.MiroTalkProvider
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter
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

  describe "detect_provider_from_url/1 (private but tested via valid_meeting_url? and extract_room_id)" do
    test "detects mirotalk" do
      assert ProviderAdapter.valid_meeting_url?("https://mirotalk.com/room")
    end

    test "detects a self-hosted mirotalk instance by the join path its URLs carry" do
      assert ProviderAdapter.valid_meeting_url?("https://talk.example.com/join/abc-def-123")

      assert ProviderAdapter.extract_room_id("https://talk.example.com/join/abc-def-123") ==
               "abc-def-123"
    end

    test "leaves links on a host merely containing \"talk.\" to their own provider" do
      # Nextcloud Talk and anything else on such a host used to be claimed by
      # MiroTalk, which then parsed a room id out of a URL it knows nothing
      # about.
      refute ProviderAdapter.valid_meeting_url?("https://talk.example.org/call/abc123")
      refute ProviderAdapter.valid_meeting_url?("https://cloud.mytalk.de/s/abc123")

      assert ProviderAdapter.extract_room_id("https://talk.example.org/call/abc123") == nil
      assert ProviderAdapter.extract_room_id("https://cloud.mytalk.de/s/abc123") == nil
    end

    test "detects google_meet" do
      assert ProviderAdapter.valid_meeting_url?("https://meet.google.com/abc-defg-hij")
    end

    test "detects teams" do
      assert ProviderAdapter.valid_meeting_url?("https://teams.microsoft.com/l/meetup-join/abc")
    end

    test "detects zoom" do
      assert ProviderAdapter.valid_meeting_url?("https://zoom.us/j/12345678901")
    end

    test "returns false for unknown provider" do
      refute ProviderAdapter.valid_meeting_url?("https://unknown.com/room")
    end
  end

  describe "extract_room_id/1" do
    test "extracts from google meet" do
      assert ProviderAdapter.extract_room_id("https://meet.google.com/abc-defg-hij") ==
               "abc-defg-hij"
    end

    test "extracts from mirotalk" do
      assert ProviderAdapter.extract_room_id("https://mirotalk.com/join/room123") == "room123"
    end

    test "returns nil for unknown provider" do
      assert ProviderAdapter.extract_room_id("https://unknown.com/room") == nil
    end
  end

  describe "extract_room_id/2" do
    # A custom video link is whatever the organiser pasted, and "/join/" is a
    # path common enough (Whereby, Jitsi, Daily) for MiroTalk's URL patterns to
    # claim links belonging to other services. MiroTalk is listed first in
    # `ProviderConfig`, so the URL-only function hands back its last path
    # segment; the id the custom provider actually minted for that link is the
    # digest it derives from the whole URL.
    @colliding_url "https://whereby.com/join/team-standup"
    @custom_room_id "176c39fdfe37cdea"

    test "parses by the named provider's rules, not by the first provider to claim the URL" do
      assert ProviderAdapter.extract_room_id(@colliding_url) == "team-standup"
      assert ProviderAdapter.extract_room_id(@colliding_url, :custom) == @custom_room_id
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

    test "returns :ok via no-op fallback for providers without the callback (MiroTalk)" do
      assert :ok = ProviderAdapter.delete_meeting_room(:mirotalk, "room123", %{})
    end

    test "returns error for unknown provider" do
      assert {:error, _reason} = ProviderAdapter.delete_meeting_room(:unknown, "room123", %{})
    end
  end

  describe "generate_meeting_metadata/1" do
    test "merges base metadata with provider info" do
      meeting_context = %{
        provider_type: :mirotalk,
        provider_module: MiroTalkProvider,
        room_data: %{room_id: "r1", meeting_url: "u1"}
      }

      metadata = ProviderAdapter.generate_meeting_metadata(meeting_context)
      assert metadata.provider_type == :mirotalk
      assert metadata.provider_name == "MiroTalk P2P"
      assert metadata.meeting_id == "r1"
    end
  end
end
