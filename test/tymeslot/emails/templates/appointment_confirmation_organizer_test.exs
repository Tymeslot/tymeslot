defmodule Tymeslot.Emails.Templates.AppointmentConfirmationOrganizerTest do
  @moduledoc """
  Organizer-side render tests for `AppointmentConfirmation`: subject lines,
  recipient, absence of an iTIP ICS attachment (the host's calendar is
  populated by CalDAV/OAuth), HTML/text body content, action links, and
  preparation reminders.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  import Tymeslot.EmailTestHelpers

  describe "render/3 as organizer" do
    test "creates email with correct subject line" do
      details = build_appointment_details()

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.subject =~ "New Appointment"
      assert email.subject =~ details.attendee_name
      assert email.subject =~ format_date_short(details.date)
    end

    test "sets correct recipient" do
      details = build_appointment_details()

      email =
        AppointmentConfirmation.render(:organizer, "organizer@test.com", details)

      assert email.to == [{"John Organizer", "organizer@test.com"}]
    end

    # Regression: the organiser email used to attach an iTIP
    # `METHOD:REQUEST` ICS. iMIP-aware mail servers (Zimbra, Exchange,
    # iCloud Mail) auto-imported that attachment as a new invitation,
    # producing a duplicate calendar event and re-firing the server-side
    # scheduling pipeline — which emailed the attendee a second time.
    # The host's own calendar is already populated via the CalDAV/OAuth
    # write path; no iMIP attachment is needed.
    test "does not attach an ICS invitation to the organiser email" do
      details = build_appointment_details()

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert Enum.all?(email.attachments, fn att ->
               not (att.content_type =~ "text/calendar")
             end)
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

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

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "Alice Johnson"
      assert email.html_body =~ "alice@company.com"
      assert email.html_body != nil
    end

    test "HTML body contains meeting details" do
      details =
        build_appointment_details(%{
          location: "Conference Room A",
          meeting_type: "Product Demo",
          duration: 45
        })

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "Conference Room A"
      assert email.html_body =~ "Product Demo"
    end

    test "HTML body contains date and time" do
      details = build_appointment_details()

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "2026"
    end

    test "HTML body includes reschedule URL" do
      details =
        build_appointment_details(%{
          reschedule_url: "https://tymeslot.com/reschedule/abc123"
        })

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "https://tymeslot.com/reschedule/abc123"
      assert email.html_body =~ "Reschedule"
    end

    test "HTML body includes cancel URL" do
      details =
        build_appointment_details(%{
          cancel_url: "https://tymeslot.com/cancel/abc123"
        })

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "https://tymeslot.com/cancel/abc123"
      assert email.html_body =~ "Cancel"
    end

    test "generates email successfully when video meeting URL is present" do
      details =
        build_appointment_details(%{
          meeting_url: "https://meet.example.com/room-123",
          organizer_video_url: "https://meet.example.com/room-123?role=host"
        })

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

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

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

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

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.text_body =~ "https://app.com/reschedule/xyz"
      assert email.text_body =~ "https://app.com/cancel/xyz"
    end

    test "text body includes preparation reminders" do
      details = build_appointment_details()

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.text_body =~ "PREPARATION"
      assert email.text_body =~ "reminder"
    end

    test "text body shows reminder message when reminders_enabled is true" do
      details =
        build_appointment_details(%{
          reminders_enabled: true,
          reminder_raw: %{value: 30, unit: "minutes"}
        })

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.text_body =~ "Set a reminder"
      assert email.text_body =~ "30 minutes"
    end

    test "text body shows no reminders message when reminders_enabled is false" do
      details = build_appointment_details(%{reminders_enabled: false})

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.text_body =~ "No reminder emails are scheduled"
    end

    test "text body defaults to reminders enabled when reminders_enabled is nil" do
      details =
        build_appointment_details(%{
          reminders_enabled: nil,
          reminder_time: "15 minutes"
        })

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.text_body =~ "Set a reminder"
      assert email.text_body =~ "15 minutes"
      refute email.text_body =~ "No reminder emails are scheduled"
    end

    test "handles optional attendee fields gracefully" do
      details =
        build_appointment_details(%{
          attendee_phone: nil,
          attendee_company: nil,
          attendee_message: nil
        })

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.html_body != nil
      assert email.text_body != nil
    end

    test "uses organizer name from details in recipient" do
      details =
        build_appointment_details(%{
          organizer_name: "Dr. Sarah Chen"
        })

      email =
        AppointmentConfirmation.render(:organizer, "sarah.chen@example.com", details)

      assert email.to == [{"Dr. Sarah Chen", "sarah.chen@example.com"}]
    end

    test "handles long attendee messages without errors" do
      long_message = String.duplicate("This is a detailed message. ", 50)

      details =
        build_appointment_details(%{
          attendee_message: long_message
        })

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

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

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.subject != nil
      assert String.length(email.subject) > 0
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert %Swoosh.Email{} = email
      assert email.subject != nil
      assert email.to != []
      assert email.html_body != nil
      assert email.text_body != nil
    end
  end
end
