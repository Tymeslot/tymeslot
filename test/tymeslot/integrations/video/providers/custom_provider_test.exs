defmodule Tymeslot.Integrations.Video.Providers.CustomProviderTest do
  use ExUnit.Case, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Providers.CustomProvider

  describe "config_schema/0" do
    test "returns schema with custom_meeting_url field" do
      schema = CustomProvider.config_schema()

      assert schema[:custom_meeting_url][:type] == :string
      assert schema[:custom_meeting_url][:required] == true
      assert schema[:custom_meeting_url][:label] == "Meeting URL"
      assert schema[:custom_meeting_url][:placeholder] == "https://meet.example.com/room123"
      assert schema[:custom_meeting_url][:help_text] =~ "complete video meeting URL"
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
      assert String.contains?(message, "required")
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

      assert room_data.room_id =~ ~r/^[a-f0-9]{16}$/
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
      assert String.contains?(message, "required")
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

          # Only the placeholder may be substituted; the rest of the template
          # has to survive verbatim.
          assert String.starts_with?(room.meeting_url, "https://jitsi.org/")

          List.last(String.split(room.meeting_url, "/"))
        end)

      # Verify all hashes are 16 characters
      assert Enum.all?(hashes, fn h -> String.length(h) == 16 end)

      # Verify all hashes are lowercase hex
      assert Enum.all?(hashes, fn h -> String.match?(h, ~r/^[a-f0-9]{16}$/) end)

      # With 2^64 possible values a 1_000-sample run must collide zero times.
      # Tolerating a rate instead would let a hash with far less entropy pass:
      # truncating to 16 bits, for instance, collides on roughly 1% of a sample
      # this size and would slip under a 1% threshold.
      unique_hashes = Enum.uniq(hashes)

      assert length(unique_hashes) == sample_size,
             "#{sample_size - length(unique_hashes)} collisions in #{sample_size} samples"

      # A hash truncated from the wrong end, or one ignoring part of its input,
      # still looks like hex — pin the value against the documented derivation.
      [first_id | _rest] = meeting_ids

      expected =
        :sha256
        |> :crypto.hash(first_id)
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      assert List.first(hashes) == expected,
             "room ids must be the first 16 hex characters of the meeting id's SHA-256"
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

      assert {:error, message} = CustomProvider.perform_connection_test(config)
      assert String.contains?(message, "fragment")
    end
  end
end
