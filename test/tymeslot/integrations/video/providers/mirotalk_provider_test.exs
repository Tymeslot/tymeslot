defmodule Tymeslot.Integrations.Video.Providers.MiroTalkProviderTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  import Mox
  alias Tymeslot.Integrations.Video.Providers.MiroTalkProvider

  setup :verify_on_exit!

  describe "provider_type/0" do
    test "returns :mirotalk" do
      assert MiroTalkProvider.provider_type() == :mirotalk
    end
  end

  describe "display_name/0" do
    test "returns correct display name" do
      assert MiroTalkProvider.display_name() == "MiroTalk P2P"
    end
  end

  describe "config_schema/0" do
    test "returns schema with required fields" do
      schema = MiroTalkProvider.config_schema()

      assert schema[:api_key][:type] == :string
      assert schema[:api_key][:required] == true
      assert schema[:base_url][:type] == :string
      assert schema[:base_url][:required] == true
    end
  end

  describe "capabilities/0" do
    test "returns correct capabilities" do
      capabilities = MiroTalkProvider.capabilities()

      assert capabilities[:recording] == false
      assert capabilities[:screen_sharing] == true
      assert capabilities[:waiting_room] == false
      assert capabilities[:max_participants] == 100
      assert capabilities[:dial_in] == false
      assert capabilities[:chat] == true
      assert capabilities[:breakout_rooms] == false
    end
  end

  describe "validate_config/1" do
    test "returns error when api_key is missing" do
      config = %{base_url: "https://mirotalk.example.com"}

      assert {:error, message} = MiroTalkProvider.validate_config(config)
      assert String.contains?(message, "api_key")
    end

    test "returns error when base_url is missing" do
      config = %{api_key: "test_api_key"}

      assert {:error, message} = MiroTalkProvider.validate_config(config)
      assert String.contains?(message, "base_url")
    end

    # `validate_config/1` is the cheap structural gate; `test_connection/1` is
    # the one function that talks to the customer's server. Callers such as
    # `ProviderRegistry.test_provider_connection/2` run both in sequence, so a
    # network call here would double every scheduled health probe.
    test "accepts a complete config without touching the network" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _http_opts ->
        {:ok, %Req.Response{status: 200}}
      end)

      assert :ok = MiroTalkProvider.validate_config(config)
    end

    test "rejects a base_url pointing at a private address without touching the network" do
      config = %{api_key: "test_key", base_url: "http://127.0.0.1:3000"}

      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _http_opts ->
        {:ok, %Req.Response{status: 200}}
      end)

      assert {:error, _message} = MiroTalkProvider.validate_config(config)
    end

    test "rejects a base_url that is not an HTTP(S) URL" do
      config = %{api_key: "test_key", base_url: "not a url"}

      assert {:error, _message} = MiroTalkProvider.validate_config(config)
    end
  end

  describe "test_connection/1" do
    test "returns error when connection fails" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, 2, fn _url, _body, _headers, _http_opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      assert {:error, message} = MiroTalkProvider.perform_connection_test(config)
      assert String.contains?(message, "Connection refused")
    end

    test "redacts and truncates error bodies in logs" do
      import ExUnit.CaptureLog
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _http_opts ->
        {:ok,
         %Req.Response{
           status: 500,
           body:
             "{\"secret_error\": \"token=ya29.secret\", \"long\": \"#{String.duplicate("a", 3000)}\"}"
         }}
      end)

      log = capture_log(fn -> MiroTalkProvider.perform_connection_test(config) end)

      assert log =~ "MiroTalk server error"
      refute log =~ "ya29.secret"
    end
  end

  describe "extract_room_id/1" do
    test "extracts room ID from full MiroTalk URL" do
      meeting_url = "https://mirotalk.example.com/join/abc-def-123"

      assert MiroTalkProvider.extract_room_id(meeting_url) == "abc-def-123"
    end

    test "extracts room ID from URL with multiple path segments" do
      meeting_url = "https://mirotalk.example.com/meeting/room/xyz-789"

      assert MiroTalkProvider.extract_room_id(meeting_url) == "xyz-789"
    end

    test "returns the URL itself if no path segments" do
      meeting_url = "https://mirotalk.example.com"

      assert MiroTalkProvider.extract_room_id(meeting_url) == meeting_url
    end

    test "handles nil input" do
      assert MiroTalkProvider.extract_room_id(nil) == nil
    end

    test "handles empty string" do
      assert MiroTalkProvider.extract_room_id("") == nil
    end
  end

  describe "valid_meeting_url?/1" do
    test "accepts valid HTTP URL" do
      assert MiroTalkProvider.valid_meeting_url?("http://mirotalk.example.com/room123")
    end

    test "accepts valid HTTPS URL" do
      assert MiroTalkProvider.valid_meeting_url?("https://mirotalk.example.com/room123")
    end

    test "rejects URL without scheme" do
      refute MiroTalkProvider.valid_meeting_url?("mirotalk.example.com/room123")
    end

    test "rejects URL with invalid scheme" do
      refute MiroTalkProvider.valid_meeting_url?("ftp://mirotalk.example.com/room123")
    end

    test "rejects empty string" do
      refute MiroTalkProvider.valid_meeting_url?("")
    end

    test "rejects URL with empty host" do
      refute MiroTalkProvider.valid_meeting_url?("https:///room123")
    end

    test "rejects malformed URLs" do
      refute MiroTalkProvider.valid_meeting_url?("https://")
      refute MiroTalkProvider.valid_meeting_url?("http://:8080")
    end
  end

  describe "sanitize_input/1" do
    test "removes special characters" do
      assert MiroTalkProvider.sanitize_input("John<script>alert(1)</script>") ==
               "Johnscriptalert1script"
    end

    test "allows letters, numbers, spaces, dots, dashes, underscores, apostrophes, and @ symbols" do
      assert MiroTalkProvider.sanitize_input("John O'Brien-Smith_123 @test.com") ==
               "John O'Brien-Smith_123 @test.com"
    end

    test "truncates to 64 characters" do
      long_name = String.duplicate("a", 100)
      result = MiroTalkProvider.sanitize_input(long_name)

      assert String.length(result) == 64
    end

    test "preserves unicode letters" do
      assert MiroTalkProvider.sanitize_input("José García") == "José García"
    end

    test "handles nil by returning empty string" do
      assert MiroTalkProvider.sanitize_input(nil) == ""
    end

    test "handles non-string input by returning empty string" do
      assert MiroTalkProvider.sanitize_input(123) == ""
    end
  end

  describe "generate_secure_token/5" do
    test "generates JWT token with correct structure" do
      config = %{api_key: "test_secret"}
      room_id = "room123"
      user_name = "John Doe"
      role = "admin"
      meeting_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      token =
        MiroTalkProvider.generate_secure_token(config, room_id, user_name, role, meeting_time)

      # JWT has 3 parts separated by dots
      parts = String.split(token, ".")
      assert length(parts) == 3

      # Decode header and verify algorithm
      [header_b64, payload_b64, _jwt_signature] = parts
      {:ok, header_json} = Base.url_decode64(header_b64, padding: false)
      header = Jason.decode!(header_json)

      assert header["alg"] == "HS256"
      assert header["typ"] == "JWT"

      # Decode payload and verify claims
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)

      assert payload["room"] == room_id
      assert payload["user"] == user_name
      assert payload["role"] == role
      assert payload["exp"] == DateTime.to_unix(meeting_time)
      # jti is a UUID v4, making each issued token individually revocable.
      assert payload["jti"] =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    end

    test "sanitizes user name in token payload" do
      config = %{api_key: "test_secret"}
      meeting_time = DateTime.utc_now()

      token =
        MiroTalkProvider.generate_secure_token(
          config,
          "room123",
          "John<script>",
          "guest",
          meeting_time
        )

      [_header, payload_b64, _jwt_signature] = String.split(token, ".")
      {:ok, payload_json} = Base.url_decode64(payload_b64, padding: false)
      payload = Jason.decode!(payload_json)

      assert payload["user"] == "Johnscript"
    end
  end

  describe "create_direct_join_url/3" do
    test "creates join URL with correct parameters" do
      config = %{base_url: "https://mirotalk.example.com"}
      room_id = "room123"
      participant_name = "John Doe"

      url = MiroTalkProvider.create_direct_join_url(config, room_id, participant_name)

      assert String.starts_with?(url, "https://mirotalk.example.com/join?")
      assert String.contains?(url, "room=room123")
      assert String.contains?(url, "name=John+Doe")
      assert String.contains?(url, "audio=1")
      assert String.contains?(url, "video=1")
      assert String.contains?(url, "screen=0")
    end

    test "sanitizes participant name in URL" do
      config = %{base_url: "https://mirotalk.example.com"}

      url =
        MiroTalkProvider.create_direct_join_url(
          config,
          "room123",
          "John<script>alert(1)</script>"
        )

      assert String.contains?(url, "name=Johnscriptalert1script")
      refute String.contains?(url, "<script>")
    end
  end

  describe "create_secure_direct_join_url/5" do
    test "creates secure join URL with token for organizer" do
      config = %{base_url: "https://mirotalk.example.com", api_key: "test_key"}
      room_id = "room123"
      participant_name = "John Doe"
      role = "organizer"
      meeting_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      url =
        MiroTalkProvider.create_secure_direct_join_url(
          config,
          room_id,
          participant_name,
          role,
          meeting_time
        )

      assert String.starts_with?(url, "https://mirotalk.example.com/join?")
      assert String.contains?(url, "room=room123")
      assert String.contains?(url, "role=admin")
      assert String.contains?(url, "screen=1")
      assert String.contains?(url, "token=")
      assert String.contains?(url, "exp=#{DateTime.to_unix(meeting_time)}")
    end

    test "creates secure join URL with token for attendee" do
      config = %{base_url: "https://mirotalk.example.com", api_key: "test_key"}
      meeting_time = DateTime.utc_now()

      url =
        MiroTalkProvider.create_secure_direct_join_url(
          config,
          "room123",
          "Guest User",
          "attendee",
          meeting_time
        )

      assert String.contains?(url, "role=guest")
      assert String.contains?(url, "screen=0")
    end
  end

  describe "create_meeting_room/1" do
    test "successfully creates a meeting room" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _http_opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"meeting" => "https://mirotalk.example.com/join/room123"})
         }}
      end)

      assert {:ok, room_data} = MiroTalkProvider.create_meeting_room(config)
      assert room_data.room_id == "https://mirotalk.example.com/join/room123"
      assert room_data.meeting_url == "https://mirotalk.example.com/join/room123"
    end

    test "returns error when API response is malformed JSON" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _http_opts ->
        {:ok, %Req.Response{status: 200, body: "not valid json{{"}}
      end)

      assert {:error, :invalid_json} = MiroTalkProvider.create_meeting_room(config)
    end

    test "returns error when a 200 response carries no room identifier" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _http_opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"unexpected" => "data"})}}
      end)

      assert {:error, :invalid_room_response} = MiroTalkProvider.create_meeting_room(config)
    end

    test "returns error when the room identifier is an empty string" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _http_opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"meeting" => ""})}}
      end)

      assert {:error, :invalid_room_response} = MiroTalkProvider.create_meeting_room(config)
    end

    test "returns error when the JSON body is not an object" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _http_opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(["room123"])}}
      end)

      assert {:error, :invalid_room_response} = MiroTalkProvider.create_meeting_room(config)
    end

    test "handles API errors gracefully" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _http_opts ->
        {:ok, %Req.Response{status: 401, body: "Unauthorized"}}
      end)

      assert {:error, {:http_error, 401, _body}} = MiroTalkProvider.create_meeting_room(config)
    end
  end

  describe "create_join_url/5" do
    test "successfully creates a join URL via API" do
      room_data = %{
        room_id: "room123",
        provider_config: %{base_url: "https://mirotalk.example.com", api_key: "test_key"}
      }

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _http_opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"join" => "https://mirotalk.example.com/join/room123?token=abc"})
         }}
      end)

      assert {:ok, join_url} =
               MiroTalkProvider.create_join_url(
                 room_data,
                 "John Doe",
                 "john@example.com",
                 "attendee",
                 DateTime.utc_now()
               )

      assert join_url == "https://mirotalk.example.com/join/room123?token=abc"
    end

    test "falls back to manual URL generation if API fails" do
      room_data = %{
        room_id: "room123",
        provider_config: %{base_url: "https://mirotalk.example.com", api_key: "test_key"}
      }

      # Mock API failure
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _http_opts ->
        {:ok, %Req.Response{status: 500, body: "Error"}}
      end)

      assert {:ok, join_url} =
               MiroTalkProvider.create_join_url(
                 room_data,
                 "John Doe",
                 "john@example.com",
                 "attendee",
                 DateTime.utc_now()
               )

      assert String.contains?(join_url, "/join?")
      assert String.contains?(join_url, "room=room123")
      assert String.contains?(join_url, "token=")
    end
  end

  describe "handle_meeting_event/3" do
    test "returns :ok for any event" do
      room_data = %{room_id: "room123", meeting_url: "https://mirotalk.example.com/room123"}

      assert MiroTalkProvider.handle_meeting_event(:started, room_data, %{}) == :ok
      assert MiroTalkProvider.handle_meeting_event(:ended, room_data, %{}) == :ok
      assert MiroTalkProvider.handle_meeting_event(:cancelled, room_data, %{}) == :ok
      assert MiroTalkProvider.handle_meeting_event(:unknown_event, room_data, %{}) == :ok
    end
  end

  describe "generate_meeting_metadata/1" do
    test "returns metadata with provider and meeting details" do
      room_data = %{
        room_id: "room123",
        meeting_url: "https://mirotalk.example.com/join/room123"
      }

      metadata = MiroTalkProvider.generate_meeting_metadata(room_data)

      assert metadata[:provider] == "mirotalk"
      assert metadata[:meeting_id] == "room123"
      assert metadata[:join_url] == "https://mirotalk.example.com/join/room123"
    end
  end
end
