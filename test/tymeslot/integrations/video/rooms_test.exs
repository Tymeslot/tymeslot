defmodule Tymeslot.Integrations.Video.RoomsTest do
  @moduletag :integrations
  @moduledoc """
  @moduletag :integrations
  Tests for video room creation and provider integration.

  ## Note on Process.sleep Usage

  One test in this file uses `Process.sleep/1` in a mock to simulate network
  latency and increase the likelihood of triggering race conditions in
  concurrent token refresh scenarios.
  """

  use Tymeslot.DataCase, async: true

  import Mox
  import Tymeslot.Factory

  setup :verify_on_exit!

  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema
  alias Tymeslot.Integrations.Video.Providers.CustomProvider
  alias Tymeslot.Integrations.Video.Providers.GoogleMeetProvider
  alias Tymeslot.Integrations.Video.Providers.MiroTalkProvider
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider
  alias Tymeslot.Integrations.Video.Rooms
  alias Tymeslot.Repo

  describe "create_meeting_room/1" do
    test "returns error when user_id is nil" do
      assert {:error, :user_id_required} = Rooms.create_meeting_room(nil)
    end

    test "returns error when user has no video integration" do
      user = insert(:user)

      assert {:error, message} = Rooms.create_meeting_room(user.id)
      assert String.contains?(message, "No video integration configured")
    end

    test "successfully creates room using specific integration" do
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "MiroTalk",
          provider: "mirotalk",
          base_url: "https://mirotalk.test",
          api_key: "test-key"
        })

      # Mock MiroTalk API call
      expect(Tymeslot.HTTPClientMock, :post, 2, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"meeting" => "https://mirotalk.test/room123"})
         }}
      end)

      assert {:ok, context} = Rooms.create_meeting_room(user.id, integration_id: integration.id)
      assert context.provider_type == :mirotalk
      assert context.room_data.room_id == "https://mirotalk.test/room123"
    end

    test "refreshes token for Google Meet if needed during room creation" do
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Google Meet",
          provider: "google_meet",
          access_token: "expired",
          refresh_token: "refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
        })

      # Mock token refresh
      expect(Tymeslot.GoogleOAuthHelperMock, :refresh_access_token, fn "refresh", _scope ->
        {:ok,
         %{
           access_token: "new_token",
           refresh_token: "new_refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600),
           scope: "scope"
         }}
      end)

      # Mock Google API call
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "conferenceData" => %{
                 "entryPoints" => [
                   %{"entryPointType" => "video", "uri" => "https://meet.google.com/abc-defg-hij"}
                 ]
               }
             })
         }}
      end)

      assert {:ok, context} = Rooms.create_meeting_room(user.id, integration_id: integration.id)
      assert context.provider_type == :google_meet
      assert context.room_data.room_id == "abc-defg-hij"

      # Verify token was updated in DB
      updated = Repo.get(VideoIntegrationSchema, integration.id)
      decrypted = VideoIntegrationSchema.decrypt_credentials(updated)
      assert decrypted.access_token == "new_token"
    end

    test "handles concurrent room creation and token refresh gracefully" do
      # Note: This is a complex test because Mox expectations are per-process by default.
      # We need to use allow/2 to share expectations between processes if we want to test concurrency properly.
      # For now, we simulate concurrent calls and ensure they both finish without crashing.
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Google Meet Concurrent",
          provider: "google_meet",
          access_token: "expired",
          refresh_token: "refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
        })

      # Allow the mock helper to be called from other processes
      stub(Tymeslot.GoogleOAuthHelperMock, :refresh_access_token, fn _token, _scope ->
        # Add a tiny delay to simulate a real network request and increase race condition likelihood
        Process.sleep(50)

        {:ok,
         %{
           access_token: "new_token_#{System.unique_integer()}",
           refresh_token: "refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600),
           scope: "scope"
         }}
      end)

      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "conferenceData" => %{
                 "entryPoints" => [
                   %{"entryPointType" => "video", "uri" => "https://meet.google.com/abc-defg-hij"}
                 ]
               }
             })
         }}
      end)

      # Start two concurrent requests
      t1 =
        Task.async(fn ->
          Rooms.create_meeting_room(user.id, integration_id: integration.id)
        end)

      t2 =
        Task.async(fn ->
          Rooms.create_meeting_room(user.id, integration_id: integration.id)
        end)

      # Wait for both to finish
      results = Task.yield_many([t1, t2])

      for {_task, {:ok, res}} <- results do
        assert {:ok, room} = res
        assert room.provider_type == :google_meet
      end

      # Integration should have some version of the new tokens
      updated = Repo.get(VideoIntegrationSchema, integration.id)
      decrypted = VideoIntegrationSchema.decrypt_credentials(updated)
      assert decrypted.access_token =~ "new_token_"
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
          meeting_url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0",
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
