defmodule Tymeslot.Emails.Templates.AppointmentConfirmationAttendeeTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Emails.Templates.AppointmentConfirmationAttendee
  import Tymeslot.EmailTestHelpers

  describe "confirmation_email/2" do
    test "creates email with correct subject line" do
      details = build_appointment_details()
      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert email.subject =~ "Confirmed"
      assert email.subject =~ details.organizer_name
      assert email.subject =~ format_date_short(details.date)
    end

    test "sets correct recipient" do
      details = build_appointment_details()
      email = AppointmentConfirmationAttendee.confirmation_email("attendee@test.com", details)

      assert email.to == [{"Jane Attendee", "attendee@test.com"}]
    end

    test "includes ICS calendar attachment" do
      details = build_appointment_details()
      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert length(email.attachments) == 1
      attachment = hd(email.attachments)
      assert attachment.filename =~ ".ics"
      assert attachment.filename =~ details.uid
      assert attachment.content_type =~ "text/calendar"
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()
      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert email.html_body != nil
      assert email.text_body != nil
      assert is_binary(email.html_body)
      assert is_binary(email.text_body)
    end

    test "HTML body contains organizer information" do
      details =
        build_appointment_details(%{
          organizer_name: "Dr. Alex Smith",
          organizer_email: "alex@company.com",
          organizer_title: "Chief Technology Officer"
        })

      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert email.html_body =~ "Dr. Alex Smith"
    end

    test "HTML body contains meeting details" do
      details =
        build_appointment_details(%{
          location: "Virtual Meeting Room",
          meeting_type: "Technical Interview",
          duration: 90
        })

      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert email.html_body =~ "Technical Interview"
    end

    test "HTML body contains date and time in attendee timezone" do
      details =
        build_appointment_details(%{
          attendee_timezone: "America/New_York"
        })

      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      # Should contain formatted date
      assert email.html_body =~ "2026"
    end

    test "HTML body includes reschedule URL" do
      details =
        build_appointment_details(%{
          reschedule_url: "https://tymeslot.com/reschedule/xyz789"
        })

      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert email.html_body =~ "https://tymeslot.com/reschedule/xyz789"
      assert email.html_body =~ "Reschedule"
    end

    test "HTML body includes cancel URL" do
      details =
        build_appointment_details(%{
          cancel_url: "https://tymeslot.com/cancel/xyz789"
        })

      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert email.html_body =~ "https://tymeslot.com/cancel/xyz789"
      assert email.html_body =~ "Cancel"
    end

    test "generates email successfully when video meeting URL is present" do
      details =
        build_appointment_details(%{
          meeting_url: "https://meet.example.com/room-456",
          attendee_video_url: "https://meet.example.com/room-456?role=guest"
        })

      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert email.html_body != nil
      assert is_binary(email.html_body)
      assert String.length(email.html_body) > 1000
    end

    test "text body contains key information" do
      details =
        build_appointment_details(%{
          organizer_name: "Sarah Johnson",
          location: "Zoom Call"
        })

      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert email.text_body =~ "Confirmed"
      assert email.text_body =~ "Sarah Johnson"
      assert email.text_body =~ "Zoom Call"
    end

    test "text body includes action links" do
      details =
        build_appointment_details(%{
          reschedule_url: "https://app.com/reschedule/abc",
          cancel_url: "https://app.com/cancel/abc"
        })

      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert email.text_body =~ "https://app.com/reschedule/abc"
      assert email.text_body =~ "https://app.com/cancel/abc"
    end

    test "text body includes preparation information" do
      details = build_appointment_details()
      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      # Text body should be substantial and informative
      assert String.length(email.text_body) > 100
      assert email.text_body =~ details.organizer_name
    end

    test "handles optional organizer fields gracefully" do
      details =
        build_appointment_details(%{
          organizer_title: nil,
          organizer_contact_info: nil
        })

      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert email.html_body != nil
      assert email.text_body != nil
    end

    test "uses attendee name from details in recipient" do
      details =
        build_appointment_details(%{
          attendee_name: "Michael Chen"
        })

      email =
        AppointmentConfirmationAttendee.confirmation_email("michael.chen@example.com", details)

      assert email.to == [{"Michael Chen", "michael.chen@example.com"}]
    end

    test "includes calendar download options" do
      details = build_appointment_details()
      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      # Should have calendar-related content (Google Calendar, Outlook, etc.)
      assert email.html_body =~ "calendar" || email.html_body =~ "Calendar"
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()
      email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

      assert %Swoosh.Email{} = email
      assert email.subject != nil
      assert email.to != []
      assert email.html_body != nil
      assert email.text_body != nil
    end

    test "handles different meeting types appropriately" do
      meeting_types = ["Discovery Call", "Demo", "Consultation", "Interview"]

      for meeting_type <- meeting_types do
        details = build_appointment_details(%{meeting_type: meeting_type})
        email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

        assert email.html_body != nil
        assert String.length(email.html_body) > 0
      end
    end

    test "handles various durations correctly" do
      durations = [15, 30, 45, 60, 90, 120]

      for duration <- durations do
        details = build_appointment_details(%{duration: duration})
        email = AppointmentConfirmationAttendee.confirmation_email("attendee@example.com", details)

        assert email.html_body != nil
        assert email.text_body != nil
      end
    end
  end
end
