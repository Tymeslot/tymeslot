defmodule Tymeslot.MeetingsContext.VideoRoomsTest do
  @moduledoc """
  Behaviour tests for the Meetings context covering video-room integration:
  creating appointments with video rooms and attaching rooms to existing meetings.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :utils

  import Mox
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Meetings
  alias Tymeslot.TestMocks
  import Tymeslot.MeetingTestHelpers

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)

    TestMocks.setup_email_mocks()
    TestMocks.setup_calendar_mocks()

    :ok
  end

  describe "when creating appointment with video room" do
    test "meeting is created even when video integration is configured" do
      %{user: user} = create_user_with_profile()

      vi =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          is_active: true
        )

      meeting_type =
        insert(:meeting_type,
          user: user,
          allow_video: true,
          video_integration_id: vi.id
        )

      meeting_params =
        build_meeting_params(user, %{
          date: Date.add(Date.utc_today(), 6),
          meeting_type_id: meeting_type.id
        })

      form_data = build_form_data()

      result = Meetings.create_appointment_with_video_room(meeting_params, form_data)

      assert {:ok, meeting} = result
      assert meeting.status == "confirmed"
    end

    test "meeting without video integration still creates successfully" do
      %{user: user} = create_user_with_profile()

      meeting_params = build_meeting_params(user, %{date: Date.add(Date.utc_today(), 7)})
      form_data = build_form_data()

      result = Meetings.create_appointment_with_video_room(meeting_params, form_data)

      assert {:ok, meeting} = result
      assert meeting.status == "confirmed"
    end
  end

  describe "when adding video room to existing meeting" do
    test "returns error when meeting does not exist" do
      result = Meetings.add_video_room_to_meeting(UUID.generate())

      assert {:error, :meeting_not_found} = result
    end

    test "returns error when user has no video integration" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      result = Meetings.add_video_room_to_meeting(meeting.id)

      assert {:error, _reason} = result
    end
  end
end
