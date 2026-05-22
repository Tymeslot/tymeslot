defmodule Tymeslot.Emails.Templates.AppointmentConfirmationAttendeeTest do
  @moduledoc """
  Attendee-side render tests for `AppointmentConfirmation`: subject lines,
  recipient, ICS attachment (METHOD:PUBLISH with SCHEDULE-AGENT=CLIENT),
  HTML/text body content, optional fields, and locale variants.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  import Tymeslot.EmailTestHelpers

  describe "render/3 as attendee" do
    test "creates email with correct subject line" do
      details = build_appointment_details()
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.subject =~ "Confirmed"
      assert email.subject =~ details.organizer_name
      assert email.subject =~ format_date_short(details.date)
    end

    test "sets correct recipient" do
      details = build_appointment_details()
      email = AppointmentConfirmation.render(:attendee, "attendee@test.com", details)

      assert email.to == [{"Jane Attendee", "attendee@test.com"}]
    end

    test "includes ICS calendar attachment" do
      details = build_appointment_details()
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))
      assert ics
      assert ics.filename =~ ".ics"
      assert ics.filename =~ details.uid
    end

    # Issue #41: a METHOD:REQUEST attachment with untagged ORGANIZER/ATTENDEE
    # triggers recipient-side iMIP handling on scheduling-aware mail servers
    # (Zimbra, Nextcloud, iCloud), which auto-imports the event and auto-RSVPs,
    # producing duplicate calendar entries and extra notification emails. The
    # attendee ICS must advertise METHOD:PUBLISH and tag both ORGANIZER and
    # ATTENDEE with SCHEDULE-AGENT=CLIENT to suppress that pipeline.
    test "attendee ICS advertises METHOD:PUBLISH with SCHEDULE-AGENT=CLIENT" do
      details = build_appointment_details()
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert ics.content_type =~ "method=PUBLISH"
      refute ics.content_type =~ "method=REQUEST"
      assert ics.data =~ "METHOD:PUBLISH"
      refute ics.data =~ "METHOD:REQUEST"
      assert ics.data =~ ~r/^ORGANIZER;SCHEDULE-AGENT=CLIENT[;:]/m
      assert ics.data =~ ~r/^ATTENDEE;SCHEDULE-AGENT=CLIENT[;:]/m
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

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

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "Dr. Alex Smith"
    end

    test "HTML body contains meeting details" do
      details =
        build_appointment_details(%{
          location: "Virtual Meeting Room",
          meeting_type: "Technical Interview",
          duration: 90
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "Technical Interview"
    end

    test "HTML body contains date and time in attendee timezone" do
      details =
        build_appointment_details(%{
          attendee_timezone: "America/New_York"
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "2026"
    end

    test "HTML body includes reschedule URL" do
      details =
        build_appointment_details(%{
          reschedule_url: "https://tymeslot.com/reschedule/xyz789"
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "https://tymeslot.com/reschedule/xyz789"
      assert email.html_body =~ "Reschedule"
    end

    test "HTML body includes cancel URL" do
      details =
        build_appointment_details(%{
          cancel_url: "https://tymeslot.com/cancel/xyz789"
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "https://tymeslot.com/cancel/xyz789"
      assert email.html_body =~ "Cancel"
    end

    test "generates email successfully when video meeting URL is present" do
      details =
        build_appointment_details(%{
          meeting_url: "https://meet.example.com/room-456",
          attendee_video_url: "https://meet.example.com/room-456?role=guest"
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert is_binary(email.html_body)
      assert email.html_body =~ "https://meet.example.com/room-456"
      assert email.html_body =~ "https://meet.example.com/room-456?role=guest"
    end

    test "text body contains key information" do
      details =
        build_appointment_details(%{
          organizer_name: "Sarah Johnson",
          location: "Video Call"
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.text_body =~ "Confirmed"
      assert email.text_body =~ "Sarah Johnson"
      assert email.text_body =~ "Video Call"
    end

    test "text body includes action links" do
      details =
        build_appointment_details(%{
          reschedule_url: "https://app.com/reschedule/abc",
          cancel_url: "https://app.com/cancel/abc"
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.text_body =~ "https://app.com/reschedule/abc"
      assert email.text_body =~ "https://app.com/cancel/abc"
    end

    test "text body includes preparation information" do
      details = build_appointment_details()
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert String.length(email.text_body) > 100
      assert email.text_body =~ details.organizer_name
    end

    test "text body handles nil reminders_summary gracefully" do
      details = build_appointment_details(%{reminders_summary: nil})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      refute email.text_body =~ "nil"
      assert String.length(email.text_body) > 100
    end

    test "text body includes reminders_summary when provided" do
      details =
        build_appointment_details(%{
          reminders_summary: "I'll send you a reminder 1 hour before our appointment."
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.text_body =~ "reminder 1 hour"
    end

    test "HTML body includes reminders_summary when provided" do
      details =
        build_appointment_details(%{
          reminders_summary: "Reminder scheduled for 30 minutes before"
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "Reminder scheduled"
    end

    test "HTML body handles nil reminders_summary gracefully" do
      details = build_appointment_details(%{reminders_summary: nil})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      refute email.html_body =~ "nil"
      assert String.length(email.html_body) > 1000
    end

    test "handles optional organizer fields gracefully" do
      details =
        build_appointment_details(%{
          organizer_title: nil,
          organizer_contact_info: nil
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.html_body != nil
      assert email.text_body != nil
    end

    test "uses attendee name from details in recipient" do
      details =
        build_appointment_details(%{
          attendee_name: "Michael Chen"
        })

      email =
        AppointmentConfirmation.render(:attendee, "michael.chen@example.com", details)

      assert email.to == [{"Michael Chen", "michael.chen@example.com"}]
    end

    test "includes calendar download options" do
      details = build_appointment_details()
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "calendar" || email.html_body =~ "Calendar"
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

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

        email =
          AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

        assert email.html_body =~ meeting_type,
               "Expected html_body to contain meeting type #{meeting_type}"
      end
    end

    test "handles various durations correctly" do
      durations = [15, 30, 45, 60, 90, 120]

      for duration <- durations do
        details = build_appointment_details(%{duration: duration})

        email =
          AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

        formatted = Formatting.format_duration(duration)

        assert email.html_body =~ formatted,
               "Expected html_body to contain duration #{formatted} for #{duration} minutes"

        assert email.text_body =~ formatted,
               "Expected text_body to contain duration #{formatted} for #{duration} minutes"
      end
    end
  end

  describe "subject CRLF injection prevention" do
    test "subject is free of CR/LF when organizer name contains header-injection payload" do
      details =
        build_appointment_details(%{
          organizer_name: "Alice\r\nBcc: attacker@evil.com"
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      refute email.subject =~ "\r"
      refute email.subject =~ "\n"
    end
  end

  describe "attendee locale rendering" do
    test "renders without error for all supported locales" do
      for locale <- ["en", "de", "uk", "fr", "it"] do
        details = build_appointment_details(%{attendee_locale: locale})
        email = AppointmentConfirmation.render(:attendee, "a@b.com", details)

        assert %Swoosh.Email{} = email,
               "Expected valid Swoosh email for locale #{locale}"

        assert is_binary(email.html_body),
               "Expected html_body for locale #{locale}"

        assert is_binary(email.text_body),
               "Expected text_body for locale #{locale}"
      end
    end

    test "German email translates subject and key body labels" do
      details = build_appointment_details(%{attendee_locale: "de"})
      email = AppointmentConfirmation.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Termin bestätigt"
      refute email.subject =~ "Appointment Confirmed"
      assert email.text_body =~ "Termin bestätigt"
      assert email.text_body =~ "TERMIN-DETAILS:"
    end

    test "French email translates subject and key body labels" do
      details = build_appointment_details(%{attendee_locale: "fr"})
      email = AppointmentConfirmation.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Rendez-vous confirmé"
      refute email.subject =~ "Appointment Confirmed"
      assert email.text_body =~ "Rendez-vous confirmé"
    end

    test "Ukrainian email translates subject and key body labels" do
      details = build_appointment_details(%{attendee_locale: "uk"})
      email = AppointmentConfirmation.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Зустріч підтверджено"
      refute email.subject =~ "Appointment Confirmed"
      assert email.text_body =~ "Зустріч підтверджено"
    end

    test "Italian email translates subject and key body labels" do
      details = build_appointment_details(%{attendee_locale: "it"})
      email = AppointmentConfirmation.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Appuntamento confermato"
      refute email.subject =~ "Appointment Confirmed"
      assert email.text_body =~ "Appuntamento confermato"
    end

    test "non-English subject uses numeric date format" do
      details = build_appointment_details(%{attendee_locale: "de", date: ~D[2026-01-15]})
      email = AppointmentConfirmation.render(:attendee, "a@b.com", details)

      assert email.subject =~ "15.1."
      refute email.subject =~ "Jan"
    end
  end

  describe "render/3 with custom field answers" do
    test "HTML body includes custom field labels and answers" do
      details =
        build_appointment_details(%{
          custom_fields_snapshot: [
            %{
              "id" => "cf-text-001",
              "type" => "short_text",
              "label" => "Notes",
              "required" => true,
              "position" => 0
            }
          ],
          custom_field_answers: %{"cf-text-001" => "Please bring documents."}
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "Notes"
      assert email.html_body =~ "Please bring documents."
    end

    test "text body includes custom field labels and answers" do
      details =
        build_appointment_details(%{
          custom_fields_snapshot: [
            %{
              "id" => "cf-text-001",
              "type" => "short_text",
              "label" => "Notes",
              "required" => true,
              "position" => 0
            }
          ],
          custom_field_answers: %{"cf-text-001" => "Please bring documents."}
        })

      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.text_body =~ "Notes"
      assert email.text_body =~ "Please bring documents."
    end
  end
end
