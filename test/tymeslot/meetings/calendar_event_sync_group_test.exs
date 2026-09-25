defmodule Tymeslot.Meetings.CalendarEventSyncGroupTest do
  @moduledoc """
  The group-booking cases of `CalendarEventSync.create/2`: the mapping of a
  meeting with no attendee of its own, and the attendee list a converted
  meeting writes to the organiser's calendar.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.GroupConversion
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries

  setup :verify_on_exit!

  describe "create/2 for a group meeting" do
    test "persists the mapping for a group meeting, which carries no attendee" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          calendar_integration_id: integration.id,
          calendar_path: "primary",
          capacity: 4,
          attendee_name: nil,
          attendee_email: nil
        )

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx ->
        {:ok, CreatedEvent.provider_minted("google-group-event")}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: integration.id, calendar_path: "primary"}}
      end)

      assert :ok = CalendarEventSync.create(meeting.id, 1)

      updated_meeting = Repo.get(MeetingSchema, meeting.id)
      assert updated_meeting.calendar_integration_id == integration.id
      assert updated_meeting.provider_event_id == "google-group-event"
    end

    test "a meeting converted from solo to group lists every live participant, not just the original attendee" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      meeting_type = insert(:meeting_type, user: user, max_participants: 1)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          meeting_type_ref: meeting_type,
          calendar_integration_id: integration.id,
          calendar_path: "primary",
          attendee_name: "Solo Booker",
          attendee_email: "solo@example.com"
        )

      # Drives the meeting through the real conversion path rather than
      # hand-building a row that carries both shapes.
      assert {:ok, 1} = GroupConversion.backfill(meeting_type.id, 4)

      {:ok, _joiner} =
        ParticipantQueries.insert(%{
          meeting_id: meeting.id,
          name: "Later Joiner",
          email: "joiner@example.com",
          timezone: "Etc/UTC",
          locale: "en"
        })

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _ctx ->
        assert event_data.description =~ "Attendees (2):"
        assert event_data.description =~ "Solo Booker <solo@example.com>"
        assert event_data.description =~ "Later Joiner <joiner@example.com>"
        {:ok, CreatedEvent.provider_minted("remote-uid-converted")}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: integration.id, calendar_path: "primary"}}
      end)

      assert :ok = CalendarEventSync.create(meeting.id, 1)
    end

    # Issue #104: a concurrent update job (enqueued once the video room
    # attached) wrote the event first, so the create's `If-None-Match: *` 412s.
  end
end
