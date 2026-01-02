defmodule Tymeslot.Integrations.Video.Providers.TeamsProviderTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Video.Providers.TeamsProvider

  describe "provider_type/0" do
    test "returns :teams" do
      assert TeamsProvider.provider_type() == :teams
    end
  end

  describe "display_name/0" do
    test "returns correct display name" do
      assert TeamsProvider.display_name() == "Microsoft Teams"
    end
  end

  describe "config_schema/0" do
    test "returns schema with required OAuth fields" do
      schema = TeamsProvider.config_schema()

      assert schema[:access_token][:type] == :string
      assert schema[:access_token][:required] == true
      assert schema[:refresh_token][:type] == :string
      assert schema[:refresh_token][:required] == true
      assert schema[:token_expires_at][:type] == :datetime
      assert schema[:token_expires_at][:required] == true
    end
  end

  describe "capabilities/0" do
    test "returns correct capabilities for Teams" do
      capabilities = TeamsProvider.capabilities()

      assert capabilities[:supports_instant_meetings] == false
      assert capabilities[:supports_scheduled_meetings] == true
      assert capabilities[:supports_recurring_meetings] == false
      assert capabilities[:supports_waiting_room] == true
      assert capabilities[:supports_recording] == true
      assert capabilities[:supports_dial_in] == true
      assert capabilities[:max_participants] == 300
      assert capabilities[:requires_account] == true
      assert capabilities[:supports_custom_branding] == false
      assert capabilities[:supports_breakout_rooms] == true
      assert capabilities[:supports_screen_sharing] == true
      assert capabilities[:supports_chat] == true
      assert capabilities[:requires_work_account] == true
    end
  end

  describe "validate_config/1" do
    test "returns error when access_token is missing" do
      config = %{
        refresh_token: "refresh_token",
        token_expires_at: DateTime.utc_now()
      }

      assert {:error, message} = TeamsProvider.validate_config(config)
      assert String.contains?(message, "access_token")
    end

    test "returns error when refresh_token is missing" do
      config = %{
        access_token: "access_token",
        token_expires_at: DateTime.utc_now()
      }

      assert {:error, message} = TeamsProvider.validate_config(config)
      assert String.contains?(message, "refresh_token")
    end

    test "returns error when token_expires_at is missing" do
      config = %{
        access_token: "access_token",
        refresh_token: "refresh_token"
      }

      assert {:error, message} = TeamsProvider.validate_config(config)
      assert String.contains?(message, "token_expires_at")
    end

    test "returns :ok when all required fields present" do
      config = %{
        access_token: "access_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.utc_now()
      }

      assert :ok = TeamsProvider.validate_config(config)
    end
  end

  describe "create_join_url/5" do
    test "creates join URL with participant display name" do
      room_data = %{
        meeting_url:
          "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc123%40thread.v2/0"
      }

      participant_name = "John Doe"
      participant_email = "john@example.com"
      role = "attendee"
      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               TeamsProvider.create_join_url(
                 room_data,
                 participant_name,
                 participant_email,
                 role,
                 meeting_time
               )

      assert String.contains?(join_url, "displayName=John")
      assert String.contains?(join_url, "Doe")
    end

    test "appends displayName to URL without existing query params" do
      room_data = %{
        meeting_url:
          "https://teams.microsoft.com/l/meetup-join/19%3ameeting_xyz789%40thread.v2/0"
      }

      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               TeamsProvider.create_join_url(
                 room_data,
                 "Alice Smith",
                 "alice@example.com",
                 "organizer",
                 meeting_time
               )

      assert String.contains?(join_url, "?displayName=Alice")
      assert String.contains?(join_url, "Smith")
    end

    test "appends displayName to URL with existing query params" do
      room_data = %{
        meeting_url:
          "https://teams.microsoft.com/l/meetup-join/19%3ameeting_xyz%40thread.v2/0?context=abc"
      }

      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               TeamsProvider.create_join_url(
                 room_data,
                 "Bob Johnson",
                 "bob@example.com",
                 "attendee",
                 meeting_time
               )

      assert String.contains?(join_url, "&displayName=Bob")
      assert String.contains?(join_url, "Johnson")
    end

    test "URL encodes special characters in participant name" do
      room_data = %{
        meeting_url:
          "https://teams.microsoft.com/l/meetup-join/19%3ameeting_test%40thread.v2/0"
      }

      meeting_time = DateTime.utc_now()

      assert {:ok, join_url} =
               TeamsProvider.create_join_url(
                 room_data,
                 "José García & María",
                 "jose@example.com",
                 "attendee",
                 meeting_time
               )

      assert String.contains?(join_url, "displayName=")
      assert String.contains?(join_url, "%")
    end
  end

  describe "extract_room_id/1" do
    test "extracts room ID from Teams meeting URL" do
      meeting_url =
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abcdefgh123456%40thread.v2/0"

      room_id = TeamsProvider.extract_room_id(meeting_url)

      assert is_binary(room_id)
      assert String.length(room_id) == 20
    end

    test "extracts room ID from Teams URL with query parameters" do
      meeting_url =
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_xyz789%40thread.v2/0?context=abc&tenantId=xyz"

      room_id = TeamsProvider.extract_room_id(meeting_url)

      assert is_binary(room_id)
      assert String.length(room_id) == 20
    end

    test "returns nil for non-Teams URL" do
      assert TeamsProvider.extract_room_id("https://zoom.us/j/123456") == nil
    end

    test "returns nil for malformed Teams URL" do
      assert TeamsProvider.extract_room_id("https://teams.microsoft.com/invalid") == nil
    end
  end

  describe "valid_meeting_url?/1" do
    test "accepts valid Teams meeting URL" do
      url = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc123%40thread.v2/0"

      assert TeamsProvider.valid_meeting_url?(url)
    end

    test "accepts Teams URL with query parameters" do
      url =
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_xyz%40thread.v2/0?context=abc"

      assert TeamsProvider.valid_meeting_url?(url)
    end

    test "rejects URL with wrong host" do
      refute TeamsProvider.valid_meeting_url?("https://zoom.us/j/123456")
      refute TeamsProvider.valid_meeting_url?("https://meet.google.com/abc-defg-hij")
    end

    test "rejects URL without meetup-join path" do
      refute TeamsProvider.valid_meeting_url?("https://teams.microsoft.com/")
      refute TeamsProvider.valid_meeting_url?("https://teams.microsoft.com/invalid/path")
    end

    test "rejects empty string" do
      refute TeamsProvider.valid_meeting_url?("")
    end
  end

  describe "handle_meeting_event/3" do
    test "returns :ok for meeting_ended event" do
      room_data = %{room_id: "meeting123"}

      assert TeamsProvider.handle_meeting_event(:meeting_ended, room_data, %{}) == :ok
    end

    test "returns :ok for other events" do
      room_data = %{room_id: "meeting123"}

      assert TeamsProvider.handle_meeting_event(:created, room_data, %{}) == :ok
      assert TeamsProvider.handle_meeting_event(:started, room_data, %{}) == :ok
      assert TeamsProvider.handle_meeting_event(:cancelled, room_data, %{}) == :ok
      assert TeamsProvider.handle_meeting_event(:unknown_event, room_data, %{}) == :ok
    end
  end

  describe "generate_meeting_metadata/1" do
    test "returns metadata with Teams-specific features" do
      room_data = %{
        room_id: "meeting123",
        meeting_url:
          "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0",
        provider_data: %{
          "passcode" => "123456",
          "toll_number" => "+1-555-0100",
          "conference_id" => "987654321"
        }
      }

      metadata = TeamsProvider.generate_meeting_metadata(room_data)

      assert metadata[:provider] == "teams"
      assert metadata[:meeting_id] == "meeting123"

      assert metadata[:join_url] ==
               "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"

      assert metadata[:passcode] == "123456"
      assert metadata[:dial_in_number] == "+1-555-0100"
      assert metadata[:conference_id] == "987654321"
    end

    test "handles missing dial-in information gracefully" do
      room_data = %{
        room_id: "meeting456",
        meeting_url:
          "https://teams.microsoft.com/l/meetup-join/19%3ameeting_xyz%40thread.v2/0",
        provider_data: %{}
      }

      metadata = TeamsProvider.generate_meeting_metadata(room_data)

      assert metadata[:provider] == "teams"
      assert metadata[:meeting_id] == "meeting456"
      assert is_nil(metadata[:passcode])
      assert is_nil(metadata[:dial_in_number])
      assert is_nil(metadata[:conference_id])
    end
  end
end
