defmodule Tymeslot.Integrations.Video.RoomsMeetingContextTest do
  @moduledoc """
  Tests for the operations that read an existing meeting context.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Mox

  setup :verify_on_exit!

  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.Providers.MiroTalkProvider
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Integrations.Video.Rooms

  describe "create_join_url/5" do
    test "requires valid meeting_context with provider_type" do
      meeting_context = %MeetingContext{
        provider_type: :mirotalk,
        provider_module: MiroTalkProvider,
        room_data: %RoomData{
          room_id: "room123",
          meeting_url: "https://mirotalk.example.com/room123",
          provider_data: %{}
        }
      }

      participant_name = "John Doe"
      participant_email = "john@example.com"
      role = "attendee"
      meeting_time = DateTime.utc_now()

      # The context carries no provider_config, so the call reaches the MiroTalk
      # adapter and is rejected there for missing parameters. That specific
      # error is what proves the context was routed to the provider at all.
      result =
        Rooms.create_join_url(
          meeting_context,
          participant_name,
          participant_email,
          role,
          meeting_time
        )

      assert {:error, :invalid_parameters} = result
    end
  end
end
