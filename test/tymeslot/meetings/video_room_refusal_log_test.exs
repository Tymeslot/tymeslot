defmodule Tymeslot.Meetings.VideoRoomRefusalLogTest do
  @moduledoc """
  A video integration switched off or waiting to be reconnected is the
  owner's to fix, and the meeting goes ahead without a room, so adding the
  room is refused without logging a failure.

  Not async: an absence assertion on a log reads the global logger, and an
  error line from a test running alongside would be indistinguishable from
  this module's own.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :video

  import ExUnit.CaptureLog

  alias Tymeslot.Meetings
  alias Tymeslot.TestMocks

  describe "add_video_room_to_meeting/1" do
    # Both refusals are the owner's to fix and the meeting goes ahead without
    # a room, so neither is logged as a failure.
    for {label, attrs, reason} <- [
          {"switched off", [is_active: false], :video_integration_inactive},
          {"waiting to be reconnected", [needs_reauth: true], :video_integration_needs_reauth}
        ] do
      test "does not log a video integration #{label} as a failure" do
        user = insert(:user)
        _profile = insert(:profile, user: user)

        video_integration =
          insert(:video_integration, [user: user, provider: "mirotalk"] ++ unquote(attrs))

        meeting =
          insert(:meeting,
            organizer_user_id: user.id,
            organizer_email: user.email,
            video_integration_id: video_integration.id
          )

        TestMocks.setup_all_mocks()

        log =
          capture_log([level: :error], fn ->
            assert {:error, unquote(reason)} = Meetings.add_video_room_to_meeting(meeting.id)
          end)

        assert log == ""
      end
    end
  end
end
