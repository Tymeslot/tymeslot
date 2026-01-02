defmodule Tymeslot.Integrations.Video.Providers.GoogleMeetProviderTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Video.Providers.GoogleMeetProvider

  describe "provider_type/0" do
    test "returns :google_meet" do
      assert GoogleMeetProvider.provider_type() == :google_meet
    end
  end

  describe "display_name/0" do
    test "returns correct display name" do
      assert GoogleMeetProvider.display_name() == "Google Meet"
    end
  end

  describe "config_schema/0" do
    test "returns schema with required OAuth fields" do
      schema = GoogleMeetProvider.config_schema()

      assert schema[:access_token][:type] == :string
      assert schema[:access_token][:required] == true
      assert schema[:refresh_token][:type] == :string
      assert schema[:refresh_token][:required] == true
      assert schema[:token_expires_at][:type] == :datetime
      assert schema[:token_expires_at][:required] == true
    end

    test "includes optional calendar_id field" do
      schema = GoogleMeetProvider.config_schema()

      assert schema[:calendar_id][:type] == :string
      assert schema[:calendar_id][:required] == false
      assert String.contains?(schema[:calendar_id][:description], "primary")
    end
  end

  describe "capabilities/0" do
    test "returns correct capabilities for Google Meet" do
      capabilities = GoogleMeetProvider.capabilities()

      assert capabilities[:recording] == true
      assert capabilities[:screen_sharing] == true
      assert capabilities[:waiting_room] == false
      assert capabilities[:max_participants] == 250
      assert capabilities[:requires_download] == false
      assert capabilities[:supports_phone_dial_in] == true
      assert capabilities[:supports_chat] == true
      assert capabilities[:supports_breakout_rooms] == true
      assert capabilities[:end_to_end_encryption] == true
      assert capabilities[:supports_live_streaming] == true
      assert capabilities[:supports_recording] == true
    end
  end

  describe "validate_config/1" do
    test "returns error when access_token is missing" do
      config = %{
        refresh_token: "refresh_token",
        token_expires_at: DateTime.utc_now()
      }

      assert {:error, message} = GoogleMeetProvider.validate_config(config)
      assert String.contains?(message, "access_token")
    end

    test "returns error when refresh_token is missing" do
      config = %{
        access_token: "access_token",
        token_expires_at: DateTime.utc_now()
      }

      assert {:error, message} = GoogleMeetProvider.validate_config(config)
      assert String.contains?(message, "refresh_token")
    end

    test "returns error when token_expires_at is missing" do
      config = %{
        access_token: "access_token",
        refresh_token: "refresh_token"
      }

      assert {:error, message} = GoogleMeetProvider.validate_config(config)
      assert String.contains?(message, "token_expires_at")
    end

    test "returns :ok when all required fields present" do
      config = %{
        access_token: "access_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.utc_now()
      }

      assert :ok = GoogleMeetProvider.validate_config(config)
    end
  end

  describe "create_join_url/5" do
    test "creates join URL with participant email and name" do
      room_data = %{meeting_url: "https://meet.google.com/abc-defg-hij"}
      participant_name = "John Doe"
      participant_email = "john@example.com"
      role = "attendee"
      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               GoogleMeetProvider.create_join_url(
                 room_data,
                 participant_name,
                 participant_email,
                 role,
                 meeting_time
               )

      assert String.starts_with?(join_url, "https://meet.google.com/abc-defg-hij?")
      assert String.contains?(join_url, "authuser=john%40example.com")
      assert String.contains?(join_url, "uname=John+Doe")
    end

    test "adds host role parameter for organizer" do
      room_data = %{meeting_url: "https://meet.google.com/abc-defg-hij"}
      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               GoogleMeetProvider.create_join_url(
                 room_data,
                 "Organizer",
                 "org@example.com",
                 "organizer",
                 meeting_time
               )

      assert String.contains?(join_url, "role=host")
    end

    test "does not add host role for attendee" do
      room_data = %{meeting_url: "https://meet.google.com/abc-defg-hij"}
      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               GoogleMeetProvider.create_join_url(
                 room_data,
                 "Attendee",
                 "att@example.com",
                 "attendee",
                 meeting_time
               )

      refute String.contains?(join_url, "role=host")
    end

    test "handles string-keyed room data" do
      room_data = %{"meeting_url" => "https://meet.google.com/xyz-abcd-efg"}
      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               GoogleMeetProvider.create_join_url(
                 room_data,
                 "User",
                 "user@example.com",
                 "attendee",
                 meeting_time
               )

      assert String.starts_with?(join_url, "https://meet.google.com/xyz-abcd-efg?")
    end

    test "returns error when meeting_url is missing" do
      room_data = %{room_id: "abc-defg-hij"}
      meeting_time = DateTime.utc_now()

      assert {:error, message} =
               GoogleMeetProvider.create_join_url(
                 room_data,
                 "User",
                 "user@example.com",
                 "attendee",
                 meeting_time
               )

      assert String.contains?(message, "Missing meeting URL")
    end
  end

  describe "extract_room_id/1" do
    test "extracts room ID from valid Google Meet URL" do
      meeting_url = "https://meet.google.com/abc-defg-hij"

      assert GoogleMeetProvider.extract_room_id(meeting_url) == "abc-defg-hij"
    end

    test "handles URL with query parameters" do
      meeting_url = "https://meet.google.com/xyz-abcd-efg?authuser=user@example.com"

      assert GoogleMeetProvider.extract_room_id(meeting_url) == "xyz-abcd-efg"
    end

    test "returns nil for non-Google Meet URL" do
      assert GoogleMeetProvider.extract_room_id("https://zoom.us/j/123456") == nil
    end

    test "returns nil for malformed Google Meet URL" do
      assert GoogleMeetProvider.extract_room_id("https://meet.google.com/") == nil
    end

    test "extracts path segment even for non-standard format" do
      # The function extracts the path segment without validating format
      assert GoogleMeetProvider.extract_room_id("https://meet.google.com/invalid") == "invalid"
    end

    test "handles nil input" do
      assert GoogleMeetProvider.extract_room_id(nil) == nil
    end

    test "handles empty string" do
      assert GoogleMeetProvider.extract_room_id("") == nil
    end
  end

  describe "valid_meeting_url?/1" do
    test "accepts valid Google Meet URL" do
      assert GoogleMeetProvider.valid_meeting_url?("https://meet.google.com/abc-defg-hij")
    end

    test "accepts Google Meet URL with query parameters" do
      assert GoogleMeetProvider.valid_meeting_url?(
               "https://meet.google.com/xyz-abcd-efg?authuser=user@example.com"
             )
    end

    test "rejects URL with wrong host" do
      refute GoogleMeetProvider.valid_meeting_url?("https://zoom.us/j/123456")
    end

    test "rejects URL with wrong format (not xxx-xxxx-xxx)" do
      refute GoogleMeetProvider.valid_meeting_url?("https://meet.google.com/invalid-format")
      refute GoogleMeetProvider.valid_meeting_url?("https://meet.google.com/abc")
      refute GoogleMeetProvider.valid_meeting_url?("https://meet.google.com/abc-def")
    end

    test "rejects URL without path" do
      refute GoogleMeetProvider.valid_meeting_url?("https://meet.google.com")
      refute GoogleMeetProvider.valid_meeting_url?("https://meet.google.com/")
    end

    test "rejects nil" do
      refute GoogleMeetProvider.valid_meeting_url?(nil)
    end

    test "rejects empty string" do
      refute GoogleMeetProvider.valid_meeting_url?("")
    end
  end

  describe "handle_meeting_event/3" do
    test "returns :ok for created event" do
      room_data = %{room_id: "abc-defg-hij"}

      assert GoogleMeetProvider.handle_meeting_event(:created, room_data, %{}) == :ok
    end

    test "returns :ok for started event" do
      room_data = %{room_id: "abc-defg-hij"}

      assert GoogleMeetProvider.handle_meeting_event(:started, room_data, %{}) == :ok
    end

    test "returns :ok for ended event" do
      room_data = %{room_id: "abc-defg-hij"}

      assert GoogleMeetProvider.handle_meeting_event(:ended, room_data, %{}) == :ok
    end

    test "returns :ok for cancelled event" do
      room_data = %{room_id: "abc-defg-hij"}

      assert GoogleMeetProvider.handle_meeting_event(:cancelled, room_data, %{}) == :ok
    end

    test "returns :ok for unknown event" do
      room_data = %{room_id: "abc-defg-hij"}

      assert GoogleMeetProvider.handle_meeting_event(:unknown_event, room_data, %{}) == :ok
    end
  end

  describe "generate_meeting_metadata/1" do
    test "returns metadata with all Google Meet features" do
      room_data = %{
        room_id: "abc-defg-hij",
        meeting_url: "https://meet.google.com/abc-defg-hij"
      }

      metadata = GoogleMeetProvider.generate_meeting_metadata(room_data)

      assert metadata[:room_id] == "abc-defg-hij"
      assert metadata[:meeting_url] == "https://meet.google.com/abc-defg-hij"
      assert metadata[:provider_name] == "Google Meet"
      assert metadata[:provider_type] == :google_meet
      assert metadata[:supports_dial_in] == true
      assert metadata[:supports_recording] == true
      assert metadata[:max_participants] == 250
      assert is_binary(metadata[:meeting_instructions])
      assert is_binary(metadata[:technical_requirements])
      assert is_list(metadata[:additional_features])
      assert "Recording available" in metadata[:additional_features]
      assert "Screen sharing" in metadata[:additional_features]
      assert "Phone dial-in available" in metadata[:additional_features]
    end

    test "supports string-keyed room data in metadata generation" do
      room_data = %{
        "room_id" => "xyz-abcd-efg",
        "meeting_url" => "https://meet.google.com/xyz-abcd-efg"
      }

      metadata = GoogleMeetProvider.generate_meeting_metadata(room_data)

      assert metadata[:room_id] == "xyz-abcd-efg"
      assert metadata[:meeting_url] == "https://meet.google.com/xyz-abcd-efg"
      assert metadata[:provider_name] == "Google Meet"
    end
  end
end
