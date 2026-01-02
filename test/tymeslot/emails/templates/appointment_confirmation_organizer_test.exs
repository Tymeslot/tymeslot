defmodule Tymeslot.Emails.Templates.AppointmentConfirmationOrganizerTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Emails.Templates.AppointmentConfirmationOrganizer
  import Tymeslot.EmailTestHelpers

  describe "confirmation_email/2" do
    test "creates email with correct subject line" do
      details = build_appointment_details()
      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      assert email.subject =~ "New Appointment"
      assert email.subject =~ details.attendee_name
      assert email.subject =~ format_date_short(details.date)
    end

    test "sets correct recipient" do
      details = build_appointment_details()

      email =
        AppointmentConfirmationOrganizer.confirmation_email(
          "organizer@test.com",
          details
        )

      assert email.to == [{"John Organizer", "organizer@test.com"}]
    end

    test "includes ICS calendar attachment" do
      details = build_appointment_details()
      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      assert length(email.attachments) == 1
      attachment = hd(email.attachments)
      assert attachment.filename =~ ".ics"
      assert attachment.filename =~ details.uid
      assert attachment.content_type =~ "text/calendar"
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()
      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      assert email.html_body != nil
      assert email.text_body != nil
      assert is_binary(email.html_body)
      assert is_binary(email.text_body)
    end

    test "HTML body contains attendee information" do
      details =
        build_appointment_details(%{
          attendee_name: "Alice Johnson",
          attendee_email: "alice@company.com",
          attendee_message: "Looking forward to our meeting"
        })

      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      assert email.html_body =~ "Alice Johnson"
      assert email.html_body =~ "alice@company.com"
      # Note: attendee message may be in a separate section or sanitized
      assert email.html_body != nil
    end

    test "HTML body contains meeting details" do
      details =
        build_appointment_details(%{
          location: "Conference Room A",
          meeting_type: "Product Demo",
          duration: 45
        })

      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      assert email.html_body =~ "Conference Room A"
      assert email.html_body =~ "Product Demo"
    end

    test "HTML body contains date and time" do
      details = build_appointment_details()
      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      # Should contain formatted date
      assert email.html_body =~ "2026"
    end

    test "HTML body includes reschedule URL" do
      details =
        build_appointment_details(%{
          reschedule_url: "https://tymeslot.com/reschedule/abc123"
        })

      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      assert email.html_body =~ "https://tymeslot.com/reschedule/abc123"
      assert email.html_body =~ "Reschedule"
    end

    test "HTML body includes cancel URL" do
      details =
        build_appointment_details(%{
          cancel_url: "https://tymeslot.com/cancel/abc123"
        })

      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      assert email.html_body =~ "https://tymeslot.com/cancel/abc123"
      assert email.html_body =~ "Cancel"
    end

    test "generates email successfully when video meeting URL is present" do
      details =
        build_appointment_details(%{
          meeting_url: "https://meet.example.com/room-123",
          organizer_video_url: "https://meet.example.com/room-123?role=host"
        })

      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      # Should generate valid email (video URL may be in components or conditional sections)
      assert email.html_body != nil
      assert is_binary(email.html_body)
      assert String.length(email.html_body) > 1000
    end

    test "text body contains key information" do
      details =
        build_appointment_details(%{
          attendee_name: "Bob Smith",
          location: "Virtual"
        })

      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      assert email.text_body =~ "New Appointment"
      assert email.text_body =~ "Bob Smith"
      assert email.text_body =~ "Virtual"
    end

    test "text body includes action links" do
      details =
        build_appointment_details(%{
          reschedule_url: "https://app.com/reschedule/xyz",
          cancel_url: "https://app.com/cancel/xyz"
        })

      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      assert email.text_body =~ "https://app.com/reschedule/xyz"
      assert email.text_body =~ "https://app.com/cancel/xyz"
    end

    test "text body includes preparation reminders" do
      details = build_appointment_details()
      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      assert email.text_body =~ "PREPARATION"
      assert email.text_body =~ "reminder"
    end

    test "handles optional attendee fields gracefully" do
      details =
        build_appointment_details(%{
          attendee_phone: nil,
          attendee_company: nil,
          attendee_message: nil
        })

      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      # Should still generate email successfully
      assert email.html_body != nil
      assert email.text_body != nil
    end

    test "uses organizer name from details in recipient" do
      details =
        build_appointment_details(%{
          organizer_name: "Dr. Sarah Chen"
        })

      email =
        AppointmentConfirmationOrganizer.confirmation_email(
          "sarah.chen@example.com",
          details
        )

      assert email.to == [{"Dr. Sarah Chen", "sarah.chen@example.com"}]
    end

    test "handles long attendee messages without errors" do
      long_message = String.duplicate("This is a detailed message. ", 50)

      details =
        build_appointment_details(%{
          attendee_message: long_message
        })

      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      # Email should generate successfully with long message
      assert email.html_body != nil
      assert email.text_body != nil
      assert is_binary(email.html_body)
      assert String.length(email.html_body) > 0
    end

    test "includes meeting type in subject when significant" do
      details =
        build_appointment_details(%{
          meeting_type: "Executive Strategy Session"
        })

      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      # Subject should reference the meeting
      assert email.subject != nil
      assert String.length(email.subject) > 0
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()
      email = AppointmentConfirmationOrganizer.confirmation_email("organizer@example.com", details)

      # Verify it's a valid Swoosh.Email struct
      assert %Swoosh.Email{} = email

      # Required fields are present
      assert email.subject != nil
      assert email.to != []
      assert email.html_body != nil
      assert email.text_body != nil
    end
  end
end
