defmodule Tymeslot.Integrations.Video.Providers.ProviderAdapterTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  import Mox
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.Providers.MiroTalkProvider
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter
  alias Tymeslot.ZoomOAuthHelperMock

  setup :verify_on_exit!

  describe "detect_provider_from_url/1 (private but tested via valid_meeting_url? and extract_room_id)" do
    test "detects mirotalk" do
      assert ProviderAdapter.valid_meeting_url?("https://mirotalk.com/room")
      assert ProviderAdapter.valid_meeting_url?("https://talk.example.com/room")
    end

    test "detects google_meet" do
      assert ProviderAdapter.valid_meeting_url?("https://meet.google.com/abc-defg-hij")
    end

    test "detects teams" do
      assert ProviderAdapter.valid_meeting_url?("https://teams.microsoft.com/l/meetup-join/abc")
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

  describe "create_meeting_room/2" do
    test "successfully creates room and handles event" do
      config = %{api_key: "key", base_url: "https://mirotalk.test"}

      # Mock MiroTalk API call
      expect(Tymeslot.HTTPClientMock, :post, 2, fn _url, _body, _headers, _opts ->
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
        oauth_scope: "meeting:write:meeting",
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
      assert {:error, _} = ProviderAdapter.update_meeting_room(:unknown, "room123", %{})
    end
  end

  describe "delete_meeting_room/3" do
    test "dispatches to provider callback and propagates return value (Zoom)" do
      config = %{
        oauth_scope: "meeting:write:meeting",
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
      assert {:error, _} = ProviderAdapter.delete_meeting_room(:unknown, "room123", %{})
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
