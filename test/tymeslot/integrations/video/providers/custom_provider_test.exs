defmodule Tymeslot.Integrations.Video.Providers.CustomProviderTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

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
      assert CustomProvider.valid_meeting_url?("https://meet.example.com/room123?param=value")
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

  describe "template variable support" do
    test "replaces {{meeting_id}} with hashed ID" do
      config = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}",
        meeting_id: "abc-123-def-456"
      }

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)

      # Should be hashed to 16 characters (lowercase hex)
      assert room_data.meeting_url =~ ~r|^https://jitsi.example.org/[a-f0-9]{16}$|
      assert String.length(List.last(String.split(room_data.meeting_url, "/"))) == 16

      assert room_data.provider_data.original_url == "https://jitsi.example.org/{{meeting_id}}"
      assert room_data.provider_data.processed_url =~ "https://jitsi.example.org/"

      # Verify consistent hashing
      {:ok, room_data2} = CustomProvider.create_meeting_room(config)
      assert room_data.meeting_url == room_data2.meeting_url
    end

    test "works without template (backward compatibility)" do
      config = %{custom_meeting_url: "https://meet.example.com/static-room"}

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)
      assert room_data.meeting_url == "https://meet.example.com/static-room"
    end

    test "returns error when meeting_id is missing for template URL" do
      config = %{custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}"}

      # When meeting_id is missing, should return error (not create broken URL)
      assert {:error, message} = CustomProvider.create_meeting_room(config)
      assert String.contains?(message, "meeting_id is required")
    end

    test "validates templates correctly" do
      config = %{custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}"}

      assert :ok = CustomProvider.validate_config(config)
    end

    test "handles multiple template instances with same hash" do
      config = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}/room-{{meeting_id}}",
        meeting_id: "test-123"
      }

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)

      # Both instances should be replaced with the same 16-character hash
      assert room_data.meeting_url =~
               ~r|^https://jitsi.example.org/[a-f0-9]{16}/room-[a-f0-9]{16}$|

      # Extract both hashed values
      [_path, hash1, hash2] =
        Regex.run(~r|/([a-f0-9]{16})/room-([a-f0-9]{16})|, room_data.meeting_url)

      assert hash1 == hash2
    end

    test "validates invalid URL with template" do
      config = %{custom_meeting_url: "not-a-url/{{meeting_id}}"}

      assert {:error, message} = CustomProvider.validate_config(config)
      assert String.contains?(message, "Invalid URL format")
    end

    test "converts non-string meeting_id to string" do
      config = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}",
        meeting_id: 12_345
      }

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)
      assert room_data.meeting_url =~ ~r|^https://jitsi.example.org/[a-f0-9]{16}$|
    end

    test "returns error when meeting_id is empty string for template URL" do
      config = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}",
        meeting_id: ""
      }

      # Empty string should return error (not create broken URL)
      assert {:error, message} = CustomProvider.create_meeting_room(config)
      assert String.contains?(message, "meeting_id is required")
    end
  end

  describe "template variable security" do
    test "prevents URL injection via special characters in meeting_id" do
      config = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}",
        meeting_id: "abc?admin=true&token=xyz"
      }

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)

      # Should be hashed, not allowing query parameter injection
      assert room_data.meeting_url =~ ~r|^https://jitsi.example.org/[a-f0-9]{16}$|
      refute String.contains?(room_data.meeting_url, "?")
      refute String.contains?(room_data.meeting_url, "&")
      refute String.contains?(room_data.meeting_url, "admin")
    end

    test "prevents fragment injection via hash character" do
      config = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}",
        meeting_id: "abc#fragment"
      }

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)

      # Should be hashed, not allowing fragment injection
      assert room_data.meeting_url =~ ~r|^https://jitsi.example.org/[a-f0-9]{16}$|
      refute String.contains?(room_data.meeting_url, "#")
    end

    test "prevents path traversal via slashes" do
      config = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}",
        meeting_id: "abc/../../admin"
      }

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)

      # Should be hashed, not allowing path traversal
      assert room_data.meeting_url =~ ~r|^https://jitsi.example.org/[a-f0-9]{16}$|
      refute String.contains?(room_data.meeting_url, "/admin")
    end

    test "handles very long meeting_id without issues" do
      long_id = String.duplicate("a", 10_000)

      config = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}",
        meeting_id: long_id
      }

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)

      # Should still produce a 16-character hash
      assert room_data.meeting_url =~ ~r|^https://jitsi.example.org/[a-f0-9]{16}$|
    end

    test "handles unicode characters in meeting_id" do
      config = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}",
        meeting_id: "встреча-会议-🎉"
      }

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)

      # Should be hashed to safe ASCII hex
      assert room_data.meeting_url =~ ~r|^https://jitsi.example.org/[a-f0-9]{16}$|
    end

    test "produces different hashes for different meeting_ids" do
      config1 = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}",
        meeting_id: "meeting-001"
      }

      config2 = %{
        custom_meeting_url: "https://jitsi.example.org/{{meeting_id}}",
        meeting_id: "meeting-002"
      }

      assert {:ok, room_data1} = CustomProvider.create_meeting_room(config1)
      assert {:ok, room_data2} = CustomProvider.create_meeting_room(config2)

      refute room_data1.meeting_url == room_data2.meeting_url
    end
  end

  describe "URL length validation" do
    test "accepts URLs within length limit" do
      # URL that will be exactly at the limit after processing
      base_url = "https://jitsi.example.org/"
      # 16-char hash + base URL should be under 255
      template_url = base_url <> "{{meeting_id}}"

      config = %{
        custom_meeting_url: template_url,
        meeting_id: "test-123"
      }

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)
      assert String.length(room_data.meeting_url) <= 255
    end

    test "rejects URLs that exceed length limit after template processing" do
      # Create a very long URL that will exceed 255 chars after processing
      long_path = String.duplicate("very-long-subdomain-name.", 10)

      template_url =
        "https://#{long_path}example.org/department/team/project/{{meeting_id}}/session?key=value&foo=bar"

      config = %{
        custom_meeting_url: template_url,
        meeting_id: "test-123"
      }

      assert {:error, message} = CustomProvider.create_meeting_room(config)
      assert String.contains?(message, "exceeds maximum length")
      assert String.contains?(message, "255")
    end

    test "validates static URLs that are too long" do
      # Static URL (no template) that's too long
      long_static_url = "https://example.org/" <> String.duplicate("a", 300)

      config = %{custom_meeting_url: long_static_url}

      assert {:error, message} = CustomProvider.create_meeting_room(config)
      assert String.contains?(message, "exceeds maximum length")
    end
  end

  describe "hash collision resistance (documentation)" do
    test "documents collision probability characteristics" do
      # This test serves as documentation of the collision characteristics
      # With 16-character hex hashes (64 bits):
      # - Total possible values: 2^64 = 18,446,744,073,709,551,616
      # - 50% collision probability (birthday paradox): ~4.3 billion meetings
      # - 1% collision probability: ~430 million meetings

      # Generate sample meetings to verify hash properties
      sample_size = 1_000
      meeting_ids = for i <- 1..sample_size, do: "meeting-#{i}-#{:rand.uniform(1_000_000)}"

      hashes =
        Enum.map(meeting_ids, fn id ->
          config = %{
            custom_meeting_url: "https://jitsi.org/{{meeting_id}}",
            meeting_id: id
          }

          {:ok, room} = CustomProvider.create_meeting_room(config)
          List.last(String.split(room.meeting_url, "/"))
        end)

      # Verify all hashes are 16 characters
      assert Enum.all?(hashes, fn h -> String.length(h) == 16 end)

      # Verify all hashes are lowercase hex
      assert Enum.all?(hashes, fn h -> String.match?(h, ~r/^[a-f0-9]{16}$/) end)

      # Calculate collision rate in sample
      unique_hashes = Enum.uniq(hashes)
      collision_rate = (sample_size - length(unique_hashes)) / sample_size

      # For 1000 samples with 2^64 possible values, collision probability is negligible
      # We expect 0 collisions in this sample size
      assert collision_rate < 0.01,
             "Unexpected collision rate: #{collision_rate * 100}% in #{sample_size} samples"
    end

    test "verifies deterministic hashing (idempotency)" do
      meeting_id = "deterministic-test-#{:rand.uniform(1_000_000)}"

      config = %{
        custom_meeting_url: "https://jitsi.org/{{meeting_id}}",
        meeting_id: meeting_id
      }

      # Create same meeting multiple times
      {:ok, room1} = CustomProvider.create_meeting_room(config)
      {:ok, room2} = CustomProvider.create_meeting_room(config)
      {:ok, room3} = CustomProvider.create_meeting_room(config)

      # All should produce identical URLs
      assert room1.meeting_url == room2.meeting_url
      assert room2.meeting_url == room3.meeting_url
    end
  end

  describe "template in URL fragment" do
    test "rejects template in fragment position" do
      config = %{
        custom_meeting_url: ~S"https://jitsi.example.org/room#{{meeting_id}}",
        meeting_id: "test-123"
      }

      assert {:error, message} = CustomProvider.create_meeting_room(config)
      assert String.contains?(message, "fragment")
      assert String.contains?(message, "not sent to the server")
    end

    test "rejects template in fragment during validation" do
      config = %{custom_meeting_url: ~S"https://jitsi.example.org/room#{{meeting_id}}"}

      assert {:error, message} = CustomProvider.validate_config(config)
      assert String.contains?(message, "fragment")
    end

    test "allows fragment without template variable" do
      config = %{custom_meeting_url: "https://meet.example.com/room#section"}

      assert :ok = CustomProvider.validate_config(config)
    end

    test "allows template in path even when fragment exists" do
      config = %{
        custom_meeting_url: ~S"https://jitsi.example.org/{{meeting_id}}#config",
        meeting_id: "test-123"
      }

      assert {:ok, room_data} = CustomProvider.create_meeting_room(config)
      # URL should contain hash in path but keep static fragment
      assert room_data.meeting_url =~ ~r|^https://jitsi.example.org/[a-f0-9]{16}#config$|
    end

    test "rejects template in fragment during test_connection" do
      config = %{custom_meeting_url: ~S"https://jitsi.example.org/room#{{meeting_id}}"}

      assert {:error, message} = CustomProvider.test_connection(config)
      assert String.contains?(message, "fragment")
    end
  end
end
