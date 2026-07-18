defmodule Tymeslot.Integrations.Calendar.CalendarEventBuilderGroupTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Meetings.ParticipantQueries

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 5)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        attendee_name: nil,
        attendee_email: nil
      )

    %{meeting: meeting}
  end

  test "group meeting description lists live participants only", %{meeting: meeting} do
    {:ok, _p1} =
      ParticipantQueries.insert(%{
        meeting_id: meeting.id,
        name: "Alice",
        email: "alice@example.com",
        timezone: "Etc/UTC",
        locale: "en"
      })

    {:ok, p2} =
      ParticipantQueries.insert(%{
        meeting_id: meeting.id,
        name: "Bob",
        email: "bob@example.com",
        timezone: "Etc/UTC",
        locale: "en"
      })

    {:ok, _cancelled} = ParticipantQueries.cancel(p2)

    description = CalendarEventBuilder.build_event_description(meeting)

    assert description =~ "Attendees (1):"
    assert description =~ "Alice <alice@example.com>"
    refute description =~ "bob@example.com"
  end

  test "solo meetings keep the existing single-attendee line" do
    meeting = insert(:meeting, attendee_name: "Solo", attendee_email: "solo@example.com")

    description = CalendarEventBuilder.build_event_description(meeting)

    assert description =~ "Attendee: Solo <solo@example.com>"
    refute description =~ "Attendees ("
  end
end
