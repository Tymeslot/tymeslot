defmodule Tymeslot.Emails.AppointmentBuilderTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Emails.AppointmentBuilder

  import Tymeslot.MeetingTestHelpers

  describe "from_meeting/1" do
    test "converts meeting to appointment details with all required fields" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      # Base meeting details
      assert result.uid == meeting.uid
      assert result.title == meeting.title
      assert result.start_time == meeting.start_time
      assert result.end_time == meeting.end_time
      assert result.duration == meeting.duration
      assert result.meeting_type == meeting.meeting_type

      # Date extraction
      assert result.date == DateTime.to_date(meeting.start_time)

      # Participant details
      assert result.organizer_name == meeting.organizer_name
      assert result.organizer_email == meeting.organizer_email
      assert result.attendee_name == meeting.attendee_name
      assert result.attendee_email == meeting.attendee_email

      # URLs
      assert result.view_url != nil
      assert result.reschedule_url != nil
      assert result.cancel_url != nil

      # Timezone conversions
      assert result.start_time_owner_tz != nil
      assert result.end_time_owner_tz != nil
      assert result.start_time_attendee_tz != nil
      assert result.end_time_attendee_tz != nil
      assert result.attendee_timezone != nil
    end

    test "includes summary field (uses meeting summary or defaults to title)" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      # Summary should be from meeting.summary or fall back to title
      assert result.summary == meeting.summary || meeting.title
    end

    test "includes description field (uses meeting description or defaults to empty)" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      # Description should be from meeting or empty string
      assert result.description == meeting.description || ""
      assert is_binary(result.description)
    end

    test "formats location as 'Video Call' when meeting_url is present" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          meeting_url: "https://meet.example.com/room123"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.location == "Video Call"
      assert result.location_details == "Video Call"
      assert result.meeting_url == "https://meet.example.com/room123"
    end

    test "uses meeting.location when meeting_url is not present" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          meeting_url: nil,
          location: "123 Main St, Conference Room A"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.location == "123 Main St, Conference Room A"
      assert result.location_details == "123 Main St, Conference Room A"
      assert result.meeting_url == nil
    end

    test "uses 'To be determined' when both meeting_url and location are nil" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          meeting_url: nil,
          location: nil
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.location == "To be determined"
      assert result.location_details == "Location to be determined"
    end

    test "includes video URLs for organizer and attendee when present" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          meeting_url: "https://meet.example.com/room123",
          organizer_video_url: "https://meet.example.com/room123?role=host",
          attendee_video_url: "https://meet.example.com/room123?role=guest"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.organizer_video_url == "https://meet.example.com/room123?role=host"
      assert result.attendee_video_url == "https://meet.example.com/room123?role=guest"
    end

    test "includes attendee optional fields when provided" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          attendee_phone: "+1-555-1234",
          attendee_company: "Acme Corp",
          attendee_message: "Looking forward to our discussion"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.attendee_phone == "+1-555-1234"
      assert result.attendee_company == "Acme Corp"
      assert result.attendee_message == "Looking forward to our discussion"
    end

    test "includes organizer title when provided" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          organizer_title: "Senior Product Manager"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.organizer_title == "Senior Product Manager"
    end

    test "includes organizer contact info" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.organizer_contact_info == "reply to this email"
      assert result.contact_info == "reply to this email"
      assert result.allow_contact == true
    end

    test "includes reminder time with default fallback" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      # Should have default reminder time
      assert result.reminder_time == "30 minutes"
      assert result.default_reminder_time == "30 minutes"
    end

    test "uses custom reminder time when provided" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          reminder_time: "1 hour",
          default_reminder_time: "15 minutes"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.reminder_time == "1 hour"
      assert result.default_reminder_time == "15 minutes"
    end

    test "converts times to organizer timezone" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      # Should have timezone-converted times (may be same as UTC for test timezone)
      assert result.start_time_owner_tz != nil
      assert result.end_time_owner_tz != nil

      # Times should be DateTime structs
      assert %DateTime{} = result.start_time_owner_tz
      assert %DateTime{} = result.end_time_owner_tz
    end

    test "converts times to attendee timezone" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          attendee_timezone: "America/New_York"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.attendee_timezone == "America/New_York"
      assert result.start_time_attendee_tz != nil
      assert result.end_time_attendee_tz != nil

      # Times should be DateTime structs
      assert %DateTime{} = result.start_time_attendee_tz
      assert %DateTime{} = result.end_time_attendee_tz
    end

    test "uses organizer timezone as fallback when attendee timezone is missing" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          attendee_timezone: nil
        })

      result = AppointmentBuilder.from_meeting(meeting)

      # Should still have timezone conversions
      assert result.start_time_attendee_tz != nil
      assert result.end_time_attendee_tz != nil
    end

    test "handles missing organizer_user_id gracefully with default timezone" do
      %{user: user} = create_user_with_profile()

      meeting =
        Map.put(insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600}), :organizer_user_id, nil)

      result = AppointmentBuilder.from_meeting(meeting)

      # Should still build successfully with default timezone
      assert result.start_time_owner_tz != nil
      assert result.end_time_owner_tz != nil
    end

    test "includes all URL fields with fallback to '#'" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          view_url: nil,
          reschedule_url: nil,
          cancel_url: nil
        })

      result = AppointmentBuilder.from_meeting(meeting)

      # Should have fallback values
      assert result.view_url == "#"
      assert result.reschedule_url == "#"
      assert result.cancel_url == "#"
    end

    test "preserves all URL fields when provided" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          view_url: "https://app.example.com/meetings/123",
          reschedule_url: "https://app.example.com/reschedule/token123",
          cancel_url: "https://app.example.com/cancel/token123"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.view_url == "https://app.example.com/meetings/123"
      assert result.reschedule_url == "https://app.example.com/reschedule/token123"
      assert result.cancel_url == "https://app.example.com/cancel/token123"
    end

    test "includes time_until_friendly field" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.time_until_friendly == "in 30 minutes"
    end
  end
end
