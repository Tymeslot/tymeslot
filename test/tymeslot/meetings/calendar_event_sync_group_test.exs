defmodule Tymeslot.Meetings.CalendarEventSyncGroupTest do
  @moduledoc """
  The group-booking cases of `CalendarEventSync.create/2`: the mapping of a
  meeting with no attendee of its own, and the attendee list a group meeting
  writes to the organiser's calendar.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings.CalendarEventSync
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

    test "a group meeting lists every live participant in the organiser's event" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      meeting =
        insert(:group_meeting,
          organizer_user_id: user.id,
          calendar_integration_id: integration.id,
          calendar_path: "primary",
          capacity: 4
        )

      {:ok, _first} =
        ParticipantQueries.insert(%{
          meeting_id: meeting.id,
          name: "First Booker",
          email: "first@example.com",
          timezone: "Etc/UTC",
          locale: "en"
        })

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
        assert event_data.description =~ "First Booker <first@example.com>"
        assert event_data.description =~ "Later Joiner <joiner@example.com>"
        {:ok, CreatedEvent.provider_minted("remote-uid-group")}
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
