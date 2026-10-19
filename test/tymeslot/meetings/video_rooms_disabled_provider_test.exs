defmodule Tymeslot.Meetings.VideoRoomsDisabledProviderTest do
  @moduledoc """
  Switching a video provider off in config stops new connections to it, but a
  booking on an integration connected before the switch still gets its room:
  the integration keeps working until its owner disconnects it.
  """

  # async: false: the provider switch is application config.
  use Tymeslot.DataCase, async: false

  @moduletag :meetings

  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Meetings.VideoRooms

  setup do
    prior = Application.fetch_env(:tymeslot, :video_providers)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:tymeslot, :video_providers, value)
        :error -> Application.delete_env(:tymeslot, :video_providers)
      end
    end)
  end

  test "a booking on an integration connected before the switch still gets its room" do
    %{user: user} = create_user_with_profile()

    integration =
      insert(:video_integration,
        user: user,
        provider: "custom",
        custom_meeting_url: "https://meet.example.com/standing-room",
        is_active: true
      )

    meeting =
      insert_meeting_for_user(user, %{
        video_integration_id: integration.id,
        video_provider: "custom"
      })

    Application.put_env(:tymeslot, :video_providers, %{custom: %{enabled: false}})
    refute :custom in ProviderConfig.all_providers()

    assert {:ok, updated} = VideoRooms.add_video_room_to_meeting(meeting.id)
    assert updated.organizer_video_url =~ "https://meet.example.com/standing-room"
  end
end
