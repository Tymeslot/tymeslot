defmodule Tymeslot.Integrations.Video.Providers.MiroTalkProviderTest do
  use ExUnit.Case, async: true

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
      assert capabilities[:requires_download] == false
      assert capabilities[:supports_phone_dial_in] == false
      assert capabilities[:supports_chat] == true
      assert capabilities[:supports_breakout_rooms] == false
      assert capabilities[:end_to_end_encryption] == true
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

    test "attempts connection when all required fields present" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 200}}
      end)

      assert :ok = MiroTalkProvider.validate_config(config)
    end

    test "returns error when connection fails" do
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, 2, fn _url, _body, _headers, _opts ->
        {:error, %HTTPoison.Error{reason: :econnrefused}}
      end)

      assert {:error, message} = MiroTalkProvider.validate_config(config)
      assert String.contains?(message, "Connection refused")
    end

    test "redacts and truncates error bodies in logs" do
      import ExUnit.CaptureLog
      config = %{api_key: "test_key", base_url: "https://mirotalk.example.com"}

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %HTTPoison.Response{
           status_code: 500,
           body: "{\"secret_error\": \"token=ya29.secret\", \"long\": \"#{String.duplicate("a", 3000)}\"}"
         }}
      end)

      log = capture_log(fn -> MiroTalkProvider.test_connection(config) end)

      assert log =~ "MiroTalk server error"
      assert log =~ "token=[REDACTED]"
      assert log =~ "[TRUNCATED]"
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

      token = MiroTalkProvider.generate_secure_token(config, room_id, user_name, role, meeting_time)

      # JWT has 3 parts separated by dots
      parts = String.split(token, ".")
      assert length(parts) == 3

      # Decode header and verify algorithm
      [header_b64, payload_b64, _signature] = parts
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
      assert is_binary(payload["jti"])
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

      [_header, payload_b64, _signature] = String.split(token, ".")
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
        MiroTalkProvider.create_direct_join_url(config, "room123", "John<script>alert(1)</script>")

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

    test "handles string-keyed room data" do
      room_data = %{
        "room_id" => "room456",
        "meeting_url" => "https://mirotalk.example.com/join/room456"
      }

      metadata = MiroTalkProvider.generate_meeting_metadata(room_data)

      assert metadata[:meeting_id] == "room456"
      assert metadata[:join_url] == "https://mirotalk.example.com/join/room456"
    end
  end
end
