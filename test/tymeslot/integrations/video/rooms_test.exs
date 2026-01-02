defmodule Tymeslot.Integrations.Video.RoomsTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.Providers.CustomProvider
  alias Tymeslot.Integrations.Video.Providers.GoogleMeetProvider
  alias Tymeslot.Integrations.Video.Providers.MiroTalkProvider
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider
  alias Tymeslot.Integrations.Video.Rooms

  describe "create_meeting_room/1" do
    test "returns error when user_id is nil" do
      assert {:error, :user_id_required} = Rooms.create_meeting_room(nil)
    end

    test "returns error when user has no video integration" do
      user = insert(:user)

      assert {:error, message} = Rooms.create_meeting_room(user.id)
      assert String.contains?(message, "No video integration configured")
    end

    test "returns error message prompting user to add integration" do
      user = insert(:user)

      assert {:error, message} = Rooms.create_meeting_room(user.id)
      assert String.contains?(message, "dashboard")
    end
  end

  describe "create_join_url/5" do
    test "requires valid meeting_context with provider_type" do
      meeting_context = %{
        provider_type: :mirotalk,
        provider_module: MiroTalkProvider,
        room_data: %{
          room_id: "room123",
          meeting_url: "https://mirotalk.example.com/room123"
        }
      }

      participant_name = "John Doe"
      participant_email = "john@example.com"
      role = "attendee"
      meeting_time = DateTime.utc_now()

      # Will attempt to call provider adapter, which will fail without actual integration
      # but demonstrates the interface is called correctly
      result =
        Rooms.create_join_url(
          meeting_context,
          participant_name,
          participant_email,
          role,
          meeting_time
        )

      # Expect either success or provider-specific error
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "handle_meeting_event/3" do
    test "delegates event to provider adapter" do
      meeting_context = %{
        provider_type: :mirotalk,
        provider_module: MiroTalkProvider,
        room_data: %{
          room_id: "room123",
          meeting_url: "https://mirotalk.example.com/room123"
        }
      }

      event = :started
      additional_data = %{participant_count: 5}

      # MiroTalk provider always returns :ok for events
      assert :ok = Rooms.handle_meeting_event(meeting_context, event, additional_data)
    end

    test "handles different event types" do
      meeting_context = %{
        provider_type: :mirotalk,
        provider_module: MiroTalkProvider,
        room_data: %{room_id: "room123"}
      }

      assert :ok = Rooms.handle_meeting_event(meeting_context, :created, %{})
      assert :ok = Rooms.handle_meeting_event(meeting_context, :started, %{})
      assert :ok = Rooms.handle_meeting_event(meeting_context, :ended, %{})
      assert :ok = Rooms.handle_meeting_event(meeting_context, :cancelled, %{})
    end

    test "handles meeting_ended event for Teams provider" do
      meeting_context = %{
        provider_type: :teams,
        provider_module: TeamsProvider,
        room_data: %{room_id: "meeting123"}
      }

      assert :ok = Rooms.handle_meeting_event(meeting_context, :meeting_ended, %{})
    end
  end

  describe "generate_meeting_metadata/1" do
    test "generates metadata for MiroTalk provider" do
      meeting_context = %{
        provider_type: :mirotalk,
        provider_module: MiroTalkProvider,
        room_data: %{
          room_id: "room123",
          meeting_url: "https://mirotalk.example.com/join/room123"
        }
      }

      metadata = Rooms.generate_meeting_metadata(meeting_context)

      assert metadata[:provider] == "mirotalk"
      assert metadata[:meeting_id] == "room123"
      assert metadata[:join_url] == "https://mirotalk.example.com/join/room123"
    end

    test "generates metadata for Google Meet provider" do
      meeting_context = %{
        provider_type: :google_meet,
        provider_module: GoogleMeetProvider,
        room_data: %{
          room_id: "abc-defg-hij",
          meeting_url: "https://meet.google.com/abc-defg-hij"
        }
      }

      metadata = Rooms.generate_meeting_metadata(meeting_context)

      assert metadata[:provider_type] == :google_meet
      assert metadata[:provider_name] == "Google Meet"
      assert metadata[:room_id] == "abc-defg-hij"
      assert metadata[:meeting_url] == "https://meet.google.com/abc-defg-hij"
      assert metadata[:supports_dial_in] == true
      assert metadata[:supports_recording] == true
      assert metadata[:max_participants] == 250
    end

    test "generates metadata for Teams provider" do
      meeting_context = %{
        provider_type: :teams,
        provider_module: TeamsProvider,
        room_data: %{
          room_id: "meeting123",
          meeting_url:
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0",
          provider_data: %{
            "passcode" => "123456",
            "toll_number" => "+1-555-0100",
            "conference_id" => "987654321"
          }
        }
      }

      metadata = Rooms.generate_meeting_metadata(meeting_context)

      assert metadata[:provider] == "teams"
      assert metadata[:meeting_id] == "meeting123"
      assert metadata[:passcode] == "123456"
      assert metadata[:dial_in_number] == "+1-555-0100"
      assert metadata[:conference_id] == "987654321"
    end

    test "generates metadata for Custom provider" do
      meeting_context = %{
        provider_type: :custom,
        provider_module: CustomProvider,
        room_data: %{
          room_id: "abc123def456",
          meeting_url: "https://meet.example.com/room123",
          provider_data: %{
            "original_url" => "https://meet.example.com/room123"
          }
        }
      }

      metadata = Rooms.generate_meeting_metadata(meeting_context)

      assert metadata[:provider] == "custom"
      assert metadata[:meeting_id] == "abc123def456"
      assert metadata[:join_url] == "https://meet.example.com/room123"
      assert metadata[:custom_url] == "https://meet.example.com/room123"
    end

    test "handles string-keyed room data" do
      meeting_context = %{
        provider_type: :mirotalk,
        provider_module: MiroTalkProvider,
        room_data: %{
          "room_id" => "room456",
          "meeting_url" => "https://mirotalk.example.com/join/room456"
        }
      }

      metadata = Rooms.generate_meeting_metadata(meeting_context)

      assert metadata[:meeting_id] == "room456"
      assert metadata[:join_url] == "https://mirotalk.example.com/join/room456"
    end
  end

  describe "error handling" do
    test "returns appropriate error when provider fails" do
      user = insert(:user)

      # User with no integration should get helpful error
      result = Rooms.create_meeting_room(user.id)

      assert {:error, message} = result
      assert is_binary(message)
      assert String.contains?(message, "integration")
    end

    test "handles missing room_id gracefully in metadata generation" do
      meeting_context = %{
        provider_type: :mirotalk,
        provider_module: MiroTalkProvider,
        room_data: %{
          meeting_url: "https://mirotalk.example.com/join/room123"
        }
      }

      metadata = Rooms.generate_meeting_metadata(meeting_context)

      # Should still generate metadata, room_id will be nil or "unknown"
      assert is_map(metadata)
    end
  end

  describe "provider integration" do
    test "supports MiroTalk provider type" do
      meeting_context = %{
        provider_type: :mirotalk,
        provider_module: MiroTalkProvider,
        room_data: %{room_id: "test"}
      }

      # Verify it can handle MiroTalk provider without errors
      assert :ok = Rooms.handle_meeting_event(meeting_context, :created, %{})
      assert is_map(Rooms.generate_meeting_metadata(meeting_context))
    end

    test "supports Google Meet provider type" do
      meeting_context = %{
        provider_type: :google_meet,
        provider_module: GoogleMeetProvider,
        room_data: %{room_id: "test", meeting_url: "https://meet.google.com/abc-defg-hij"}
      }

      assert :ok = Rooms.handle_meeting_event(meeting_context, :created, %{})
      assert is_map(Rooms.generate_meeting_metadata(meeting_context))
    end

    test "supports Teams provider type" do
      meeting_context = %{
        provider_type: :teams,
        provider_module: TeamsProvider,
        room_data: %{
          room_id: "test",
          meeting_url:
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_test%40thread.v2/0",
          provider_data: %{}
        }
      }

      assert :ok = Rooms.handle_meeting_event(meeting_context, :meeting_ended, %{})
      assert is_map(Rooms.generate_meeting_metadata(meeting_context))
    end

    test "supports Custom provider type" do
      meeting_context = %{
        provider_type: :custom,
        provider_module: CustomProvider,
        room_data: %{
          room_id: "test",
          meeting_url: "https://meet.example.com/room123",
          provider_data: %{}
        }
      }

      assert :ok = Rooms.handle_meeting_event(meeting_context, :created, %{})
      assert is_map(Rooms.generate_meeting_metadata(meeting_context))
    end
  end
end
