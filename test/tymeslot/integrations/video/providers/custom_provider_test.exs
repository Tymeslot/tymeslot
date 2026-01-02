defmodule Tymeslot.Integrations.Video.Providers.CustomProviderTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Video.Providers.CustomProvider

  describe "provider_type/0" do
    test "returns :custom" do
      assert CustomProvider.provider_type() == :custom
    end
  end

  describe "display_name/0" do
    test "returns correct display name" do
      assert CustomProvider.display_name() == "Custom Video Link"
    end
  end

  describe "config_schema/0" do
    test "returns schema with custom_meeting_url field" do
      schema = CustomProvider.config_schema()

      assert schema[:custom_meeting_url][:type] == :string
      assert schema[:custom_meeting_url][:required] == true
      assert is_binary(schema[:custom_meeting_url][:label])
      assert is_binary(schema[:custom_meeting_url][:help_text])
      assert is_binary(schema[:custom_meeting_url][:placeholder])
    end
  end

  describe "capabilities/0" do
    test "returns correct capabilities for custom provider" do
      capabilities = CustomProvider.capabilities()

      assert capabilities[:supports_instant_meetings] == true
      assert capabilities[:supports_scheduled_meetings] == true
      assert capabilities[:supports_recurring_meetings] == true
      assert capabilities[:supports_waiting_room] == false
      assert capabilities[:supports_recording] == false
      assert capabilities[:supports_dial_in] == false
      assert capabilities[:max_participants] == nil
      assert capabilities[:requires_account] == false
      assert capabilities[:supports_custom_branding] == true
      assert capabilities[:supports_breakout_rooms] == false
      assert capabilities[:supports_screen_sharing] == false
      assert capabilities[:supports_chat] == false
      assert capabilities[:requires_work_account] == false
      assert capabilities[:is_custom_provider] == true
    end
  end

  describe "validate_config/1" do
    test "returns error when custom_meeting_url is missing" do
      config = %{}

      assert {:error, message} = CustomProvider.validate_config(config)
      assert String.contains?(message, "required")
    end

    test "returns error when custom_meeting_url is empty" do
      config = %{custom_meeting_url: ""}

      assert {:error, message} = CustomProvider.validate_config(config)
      assert String.contains?(message, "cannot be empty")
    end

    test "returns error for invalid URL format" do
      config = %{custom_meeting_url: "not-a-url"}

      assert {:error, message} = CustomProvider.validate_config(config)
      assert String.contains?(message, "Invalid URL format")
    end

    test "returns :ok for valid HTTPS URL" do
      config = %{custom_meeting_url: "https://meet.example.com/room123"}

      assert :ok = CustomProvider.validate_config(config)
    end

    test "returns :ok for valid HTTP URL" do
      config = %{custom_meeting_url: "http://meet.example.com/room123"}

      assert :ok = CustomProvider.validate_config(config)
    end
  end

  describe "create_meeting_room/1" do
    test "creates room data with custom URL" do
      config = %{custom_meeting_url: "https://meet.example.com/room123"}

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)

      assert is_binary(room_data.room_id)
      assert room_data.meeting_url == "https://meet.example.com/room123"
      assert room_data.provider_data.original_url == "https://meet.example.com/room123"
      assert %DateTime{} = room_data.provider_data.created_at
    end

    test "returns error when custom_meeting_url is missing" do
      config = %{}

      assert {:error, message} = CustomProvider.create_meeting_room(config)
      assert String.contains?(message, "required")
    end

    test "returns error when custom_meeting_url is empty" do
      config = %{custom_meeting_url: ""}

      assert {:error, message} = CustomProvider.create_meeting_room(config)
      assert String.contains?(message, "cannot be empty")
    end

    test "returns error for invalid URL" do
      config = %{custom_meeting_url: "not-a-valid-url"}

      assert {:error, message} = CustomProvider.create_meeting_room(config)
      assert String.contains?(message, "Invalid URL format")
    end

    test "generates consistent room_id for same URL" do
      config = %{custom_meeting_url: "https://meet.example.com/room123"}

      {:ok, room_data1} = CustomProvider.create_meeting_room(config)
      {:ok, room_data2} = CustomProvider.create_meeting_room(config)

      assert room_data1.room_id == room_data2.room_id
    end

    test "generates different room_id for different URLs" do
      config1 = %{custom_meeting_url: "https://meet.example.com/room123"}
      config2 = %{custom_meeting_url: "https://meet.example.com/room456"}

      {:ok, room_data1} = CustomProvider.create_meeting_room(config1)
      {:ok, room_data2} = CustomProvider.create_meeting_room(config2)

      assert room_data1.room_id != room_data2.room_id
    end
  end

  describe "create_join_url/5" do
    test "returns the meeting URL unchanged" do
      room_data = %{meeting_url: "https://meet.example.com/room123"}
      participant_name = "John Doe"
      participant_email = "john@example.com"
      role = "attendee"
      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               CustomProvider.create_join_url(
                 room_data,
                 participant_name,
                 participant_email,
                 role,
                 meeting_time
               )

      assert join_url == "https://meet.example.com/room123"
    end

    test "ignores participant information" do
      room_data = %{meeting_url: "https://meet.example.com/special-room"}
      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               CustomProvider.create_join_url(
                 room_data,
                 "Any Name",
                 "any@email.com",
                 "organizer",
                 meeting_time
               )

      assert join_url == "https://meet.example.com/special-room"
    end
  end

  describe "extract_room_id/1" do
    test "generates MD5 hash of URL" do
      url = "https://meet.example.com/room123"

      room_id = CustomProvider.extract_room_id(url)

      assert is_binary(room_id)
      assert String.length(room_id) == 16
      assert room_id =~ ~r/^[a-f0-9]{16}$/
    end

    test "generates consistent hash for same URL" do
      url = "https://meet.example.com/room123"

      room_id1 = CustomProvider.extract_room_id(url)
      room_id2 = CustomProvider.extract_room_id(url)

      assert room_id1 == room_id2
    end

    test "generates different hash for different URLs" do
      url1 = "https://meet.example.com/room123"
      url2 = "https://meet.example.com/room456"

      room_id1 = CustomProvider.extract_room_id(url1)
      room_id2 = CustomProvider.extract_room_id(url2)

      assert room_id1 != room_id2
    end
  end

  describe "valid_meeting_url?/1" do
    test "accepts valid HTTPS URL" do
      assert CustomProvider.valid_meeting_url?("https://meet.example.com/room123")
    end

    test "accepts valid HTTP URL" do
      assert CustomProvider.valid_meeting_url?("http://meet.example.com/room123")
    end

    test "accepts URL with query parameters" do
      assert CustomProvider.valid_meeting_url?(
               "https://meet.example.com/room123?param=value"
             )
    end

    test "accepts URL with port number" do
      assert CustomProvider.valid_meeting_url?("https://meet.example.com:8443/room123")
    end

    test "rejects URL without scheme" do
      refute CustomProvider.valid_meeting_url?("meet.example.com/room123")
    end

    test "rejects URL with invalid scheme" do
      refute CustomProvider.valid_meeting_url?("ftp://meet.example.com/room123")
      refute CustomProvider.valid_meeting_url?("ws://meet.example.com/room123")
    end

    test "rejects URL with empty host" do
      refute CustomProvider.valid_meeting_url?("https:///room123")
    end

    test "rejects malformed URLs" do
      refute CustomProvider.valid_meeting_url?("https://")
      refute CustomProvider.valid_meeting_url?("http://:8080")
    end

    test "rejects nil" do
      refute CustomProvider.valid_meeting_url?(nil)
    end

    test "rejects empty string" do
      refute CustomProvider.valid_meeting_url?("")
    end

    test "rejects non-string values" do
      refute CustomProvider.valid_meeting_url?(123)
      refute CustomProvider.valid_meeting_url?([])
    end
  end

  describe "handle_meeting_event/3" do
    test "returns :ok for any event" do
      room_data = %{meeting_url: "https://meet.example.com/room123"}

      assert CustomProvider.handle_meeting_event(:created, room_data, %{}) == :ok
      assert CustomProvider.handle_meeting_event(:started, room_data, %{}) == :ok
      assert CustomProvider.handle_meeting_event(:ended, room_data, %{}) == :ok
      assert CustomProvider.handle_meeting_event(:cancelled, room_data, %{}) == :ok
      assert CustomProvider.handle_meeting_event(:unknown_event, room_data, %{}) == :ok
    end
  end

  describe "generate_meeting_metadata/1" do
    test "returns metadata with custom provider info" do
      room_data = %{
        room_id: "abc123def456",
        meeting_url: "https://meet.example.com/room123",
        provider_data: %{
          "original_url" => "https://meet.example.com/room123"
        }
      }

      metadata = CustomProvider.generate_meeting_metadata(room_data)

      assert metadata[:provider] == "custom"
      assert metadata[:meeting_id] == "abc123def456"
      assert metadata[:join_url] == "https://meet.example.com/room123"
      assert metadata[:custom_url] == "https://meet.example.com/room123"
    end

    test "handles missing provider_data gracefully" do
      room_data = %{
        room_id: "xyz789",
        meeting_url: "https://meet.example.com/room456",
        provider_data: %{}
      }

      metadata = CustomProvider.generate_meeting_metadata(room_data)

      assert metadata[:provider] == "custom"
      assert metadata[:meeting_id] == "xyz789"
      assert is_nil(metadata[:custom_url])
    end
  end
end
