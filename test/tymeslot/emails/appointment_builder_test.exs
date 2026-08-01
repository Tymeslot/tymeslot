defmodule Tymeslot.Emails.AppointmentBuilderTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Profiles

  import Tymeslot.MeetingTestHelpers

  describe "from_meeting/1" do
    test "converts meeting to appointment details with all required fields" do
      %{user: user, profile: profile} = create_user_with_profile()
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

      # URLs: only reschedule_url is set by the factory; the other two fall back
      assert result.view_url == "#"
      assert result.reschedule_url == meeting.reschedule_url
      assert result.cancel_url == "#"

      # Timezone conversions: the same instants, expressed in each party's zone
      assert result.attendee_timezone == meeting.attendee_timezone
      assert %DateTime{time_zone: owner_tz} = result.start_time_owner_tz
      assert owner_tz == profile.timezone
      assert %DateTime{time_zone: ^owner_tz} = result.end_time_owner_tz
      assert %DateTime{time_zone: "America/New_York"} = result.start_time_attendee_tz
      assert %DateTime{time_zone: "America/New_York"} = result.end_time_attendee_tz
      assert DateTime.compare(result.start_time_owner_tz, meeting.start_time) == :eq
      assert DateTime.compare(result.end_time_attendee_tz, meeting.end_time) == :eq
    end

    test "uses the meeting summary when the meeting has one" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          summary: "Quarterly roadmap review"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.summary == "Quarterly roadmap review"
    end

    test "falls back to the title when the meeting has no summary" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          summary: nil,
          title: "Discovery Call"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.summary == "Discovery Call"
    end

    test "uses the meeting description when the meeting has one" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          description: "Bring the latest funnel numbers."
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.description == "Bring the latest funnel numbers."
    end

    test "falls back to an empty description when the meeting has none" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600, description: nil})

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.description == ""
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

    test "leaves location nil so the renderer substitutes the localised TBD label" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          meeting_url: nil,
          location: nil
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.location == nil
      assert result.location_details == nil
    end

    test "treats the legacy 'To be determined' placeholder as an unset location" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          meeting_url: nil,
          location: "To be determined"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.location == nil
      assert result.location_details == nil
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

    test "includes reminder time from meeting reminders" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          reminders: [%{value: 30, unit: "minutes"}]
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.reminder_time == "30 minutes"
      assert result.default_reminder_time == "30 minutes"
      assert result.reminders_enabled == true
    end

    test "uses legacy reminder time fields when no reminder list exists" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          reminders: [],
          reminder_time: "1 hour",
          default_reminder_time: "15 minutes"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.reminder_time == "1 hour"
      assert result.default_reminder_time == "1 hour"
      assert result.reminders_enabled == true
    end

    test "handles meetings with no reminders configured" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          reminders: [],
          reminder_time: nil,
          default_reminder_time: nil
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.reminders_enabled == false
      assert result.reminder_time == nil
      assert result.default_reminder_time == nil
      assert result.reminders_summary == "No reminder emails are scheduled for this appointment."
    end

    test "converts times to organizer timezone" do
      %{user: user} = create_user_with_profile(%{timezone: "America/Chicago"})
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      assert %DateTime{time_zone: "America/Chicago"} = result.start_time_owner_tz
      assert %DateTime{time_zone: "America/Chicago"} = result.end_time_owner_tz

      # Converted, not shifted: the same instants as the stored UTC times
      assert DateTime.compare(result.start_time_owner_tz, meeting.start_time) == :eq
      assert DateTime.compare(result.end_time_owner_tz, meeting.end_time) == :eq
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
      assert %DateTime{time_zone: "America/New_York"} = result.start_time_attendee_tz
      assert %DateTime{time_zone: "America/New_York"} = result.end_time_attendee_tz

      # Converted, not shifted: the same instants as the stored UTC times
      assert DateTime.compare(result.start_time_attendee_tz, meeting.start_time) == :eq
      assert DateTime.compare(result.end_time_attendee_tz, meeting.end_time) == :eq
    end

    test "uses organizer timezone as fallback when attendee timezone is missing" do
      %{user: user, profile: profile} = create_user_with_profile(%{timezone: "America/Chicago"})

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          attendee_timezone: nil
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.attendee_timezone == profile.timezone
      assert %DateTime{time_zone: "America/Chicago"} = result.start_time_attendee_tz
      assert %DateTime{time_zone: "America/Chicago"} = result.end_time_attendee_tz
    end

    test "handles missing organizer_user_id gracefully with default timezone" do
      %{user: user} = create_user_with_profile(%{timezone: "America/Chicago"})

      meeting =
        Map.put(
          insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600}),
          :organizer_user_id,
          nil
        )

      result = AppointmentBuilder.from_meeting(meeting)

      # Falls back to the application default rather than the organizer's own zone
      default_timezone = Profiles.get_default_timezone()

      assert %DateTime{time_zone: ^default_timezone} = result.start_time_owner_tz
      assert %DateTime{time_zone: ^default_timezone} = result.end_time_owner_tz
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

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          reminder_time: "30 minutes"
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.time_until_friendly == "in 30 minutes"
    end

    test "uses reminder interval when provided" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting, %{value: 1, unit: "hours"})

      assert result.time_until == "1 hour"
      assert result.time_until_friendly == "in 1 hour"
    end

    test "propagates attendee_locale from meeting to appointment details" do
      %{user: user} = create_user_with_profile()
      # Default factory sets attendee_locale: "en"
      meeting = insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600})

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.attendee_locale == "en"
    end

    test "propagates non-English attendee_locale from meeting to appointment details" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600, attendee_locale: "de"})

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.attendee_locale == "de"
    end

    test "localized_reminder_label reflects attendee_locale" do
      %{user: user} = create_user_with_profile()

      en_meeting =
        insert_meeting_for_user(user, %{start_offset: 3600, duration: 3600, attendee_locale: "en"})

      de_meeting =
        insert_meeting_for_user(user, %{start_offset: 7200, duration: 3600, attendee_locale: "de"})

      en_result = AppointmentBuilder.from_meeting(en_meeting, %{value: 15, unit: "minutes"})
      de_result = AppointmentBuilder.from_meeting(de_meeting, %{value: 15, unit: "minutes"})

      refute en_result.reminder_time == de_result.reminder_time
    end

    test "threads custom_fields_snapshot and custom_field_answers through to appointment details" do
      %{user: user} = create_user_with_profile()

      snapshot = [
        %{
          "id" => "cf-text-001",
          "type" => "short_text",
          "label" => "Notes",
          "required" => true,
          "position" => 0
        }
      ]

      answers = %{"cf-text-001" => "Please bring documents."}

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 3600,
          duration: 3600,
          custom_fields_snapshot: snapshot,
          custom_field_answers: answers
        })

      result = AppointmentBuilder.from_meeting(meeting)

      assert result.custom_fields_snapshot == snapshot
      assert result.custom_field_answers == answers
    end
  end
end
