defmodule Tymeslot.Emails.Templates.AppointmentReminderTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Emails.Templates.AppointmentReminder
  import Tymeslot.EmailTestHelpers

  describe "render/3 as organizer" do
    test "creates email with correct subject line" do
      details = build_appointment_details(%{time_until: "30 minutes"})
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.subject =~ "Meeting"
      assert email.subject =~ details.attendee_name
      assert email.subject =~ "30 minutes"
    end

    test "sets correct recipient" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:organizer, "organizer@test.com", details)

      assert email.to == [{"John Organizer", "organizer@test.com"}]
    end

    test "carries the inline logo but no calendar attachment" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      # The reminder points at an already-booked meeting, so it ships no ICS —
      # the only attachment is the logo the template references inline.
      assert [%Swoosh.Attachment{filename: "tymeslot-logo.png", content_type: "image/png"}] =
               email.attachments
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "<!doctype html"
      assert email.html_body =~ details.attendee_name
      assert email.text_body =~ details.attendee_name
    end

    test "HTML body contains time until meeting" do
      details = build_appointment_details(%{time_until: "1 hour"})
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "1 hour"
    end

    test "HTML body contains attendee information" do
      details =
        build_appointment_details(%{
          attendee_name: "Emily Wilson",
          attendee_email: "emily@company.com"
        })

      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "Emily Wilson"
    end

    test "HTML body contains meeting details" do
      details =
        build_appointment_details(%{
          meeting_type: "Strategy Session",
          location: "Conference Room B"
        })

      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "Strategy Session"
      assert email.html_body =~ "Conference Room B"
    end

    test "HTML body includes action links" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ details.reschedule_url
      assert email.html_body =~ details.cancel_url
    end

    test "generates valid email with video meeting URL" do
      details =
        build_appointment_details(%{
          meeting_url: "https://meet.example.com/reminder-test"
        })

      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "https://meet.example.com/reminder-test"
      assert String.length(email.html_body) > 1000
    end

    test "text body contains key reminder information" do
      details = build_appointment_details(%{time_until: "15 minutes"})
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.text_body =~ details.attendee_name
      assert String.length(email.text_body) > 100
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert %Swoosh.Email{subject: subject, to: to} = email
      assert subject =~ "Meeting with #{details.attendee_name}"
      assert to == [{"John Organizer", "organizer@example.com"}]
    end

    test "organizer subject is free of CR/LF when attendee name contains header-injection payload" do
      details =
        build_appointment_details(%{
          attendee_name: "Bob\r\nBcc: attacker@evil.com"
        })

      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      refute email.subject =~ "\r"
      refute email.subject =~ "\n"
    end
  end

  describe "render/3 as attendee" do
    test "creates email with correct subject line" do
      details = build_appointment_details(%{time_until: "30 minutes"})
      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.subject =~ "Reminder"
      assert email.subject =~ "30 minutes"
    end

    test "sets correct recipient" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:attendee, "attendee@test.com", details)

      assert email.to == [{"Jane Attendee", "attendee@test.com"}]
    end

    test "carries the inline logo but no calendar attachment" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert [%Swoosh.Attachment{filename: "tymeslot-logo.png", content_type: "image/png"}] =
               email.attachments
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "<!doctype html"
      assert email.html_body =~ details.organizer_name
      assert email.text_body =~ details.organizer_name
    end

    test "HTML body contains time until meeting" do
      details = build_appointment_details(%{time_until: "2 hours"})
      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "2 hours"
    end

    test "HTML body contains organizer information" do
      details =
        build_appointment_details(%{
          organizer_name: "Dr. Rebecca Martinez",
          organizer_email: "rebecca@company.com"
        })

      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "Dr. Rebecca Martinez"
    end

    test "HTML body contains meeting details" do
      details =
        build_appointment_details(%{
          meeting_type: "Technical Review",
          location: "Video Conference"
        })

      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "Technical Review"
      assert email.html_body =~ "Video Conference"
    end

    test "HTML body includes action links" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ details.reschedule_url
      assert email.html_body =~ details.cancel_url
    end

    test "generates valid email with video meeting URL" do
      details =
        build_appointment_details(%{
          meeting_url: "https://meet.example.com/attendee-reminder"
        })

      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ "https://meet.example.com/attendee-reminder"
      assert String.length(email.html_body) > 1000
    end

    test "text body contains key reminder information" do
      details = build_appointment_details(%{time_until: "45 minutes"})
      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.text_body =~ details.organizer_name
      assert String.length(email.text_body) > 100
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert %Swoosh.Email{subject: subject, to: to} = email
      assert subject =~ "Reminder:"
      assert to == [{"Jane Attendee", "attendee@example.com"}]
    end

    test "handles different time_until values correctly" do
      time_values = ["15 minutes", "30 minutes", "1 hour", "2 hours", "1 day"]

      for time_until <- time_values do
        details = build_appointment_details(%{time_until: time_until})
        email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

        assert email.html_body =~ time_until
        assert email.subject =~ time_until
      end
    end

    test "includes timezone-aware time display" do
      # start_time is 14:00 UTC; the attendee sits in America/Los_Angeles
      # (UTC-8 in January), so their local start is 06:00 — represented here
      # by a distinct DateTime so the two are told apart in the output.
      utc_start = ~U[2026-01-15 14:00:00Z]
      attendee_local_start = %{utc_start | hour: 6}

      details =
        build_appointment_details(%{
          start_time: utc_start,
          start_time_attendee_tz: attendee_local_start,
          attendee_timezone: "America/Los_Angeles"
        })

      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      formatted_attendee = Formatting.format_time(attendee_local_start, "en")
      formatted_utc = Formatting.format_time(utc_start, "en")

      assert email.html_body =~ formatted_attendee,
             "Expected attendee-local time #{formatted_attendee} in HTML body"

      refute email.html_body =~ formatted_utc,
             "Expected raw UTC time #{formatted_utc} to be absent from HTML body"

      assert email.html_body =~ "America/Los_Angeles"
    end
  end

  describe "attendee locale rendering" do
    test "renders without error for all supported locales" do
      for locale <- ["en", "de", "uk", "fr", "it"] do
        details = build_appointment_details(%{attendee_locale: locale})
        email = AppointmentReminder.render(:attendee, "a@b.com", details)

        assert %Swoosh.Email{} = email,
               "Expected valid Swoosh email for locale #{locale}"

        assert is_binary(email.html_body),
               "Expected html_body for locale #{locale}"

        assert is_binary(email.text_body),
               "Expected text_body for locale #{locale}"
      end
    end

    test "German reminder uses translated subject and body header" do
      details = build_appointment_details(%{attendee_locale: "de"})
      email = AppointmentReminder.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Erinnerung"
      refute email.subject =~ "Reminder"
      assert email.text_body =~ "ERINNERUNG:"
    end

    test "French reminder uses translated subject" do
      details = build_appointment_details(%{attendee_locale: "fr"})
      email = AppointmentReminder.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Rappel"
      refute email.subject =~ "Reminder"
      assert email.text_body =~ "RAPPEL :"
    end

    test "Ukrainian reminder uses translated subject" do
      details = build_appointment_details(%{attendee_locale: "uk"})
      email = AppointmentReminder.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Нагадування"
      refute email.subject =~ "Reminder"
      assert email.text_body =~ "НАГАДУВАННЯ:"
    end

    test "Italian reminder uses translated subject" do
      details = build_appointment_details(%{attendee_locale: "it"})
      email = AppointmentReminder.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Promemoria"
      refute email.subject =~ "Reminder"
      assert email.text_body =~ "PROMEMORIA:"
    end
  end
end
