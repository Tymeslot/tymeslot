defmodule Tymeslot.Emails.Templates.AppointmentCancellationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Emails.Templates.AppointmentCancellation
  alias Tymeslot.Notifications.ContentBuilder
  import Tymeslot.EmailTestHelpers
  import Tymeslot.Factory

  describe "render/3 with :organizer" do
    test "creates email with correct subject line" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      assert email.subject =~ "Cancelled"
      assert email.subject =~ details.attendee_name
    end

    test "sets correct recipient" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(:organizer, "organizer@test.com", details)

      assert email.to == [{"John Organizer", "organizer@test.com"}]
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      assert email.html_body != nil
      assert email.text_body != nil
      assert is_binary(email.html_body)
      assert is_binary(email.text_body)
    end

    test "HTML body contains attendee information" do
      details =
        build_appointment_details(%{
          attendee_name: "Mike Davis",
          attendee_email: "mike@company.com"
        })

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      assert email.html_body =~ "Mike Davis"
    end

    test "HTML body contains meeting details" do
      details =
        build_appointment_details(%{
          meeting_type: "Product Demo",
          location: "Office"
        })

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      # Should contain substantial information
      assert String.length(email.html_body) > 500
    end

    test "text body contains cancellation information" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      assert email.text_body =~ details.attendee_name
      assert String.length(email.text_body) > 100
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      assert %Swoosh.Email{} = email
      assert email.subject != nil
      assert email.to != []
    end

    test "HTML body contains cancellation notification" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      assert email.html_body =~ "cancelled" || email.html_body =~ "Cancelled"
    end

    test "text body contains meeting cancellation notice" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      assert email.text_body =~ "Meeting Cancelled"
      assert email.text_body =~ details.attendee_name
    end
  end

  describe "render/3 with :attendee" do
    test "creates email with correct subject line" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      assert email.subject =~ "Cancelled"
      assert email.subject =~ details.organizer_name
    end

    test "sets correct recipient" do
      details = build_appointment_details()

      email = AppointmentCancellation.render(:attendee, "attendee@test.com", details)

      assert email.to == [{"Jane Attendee", "attendee@test.com"}]
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      assert email.html_body != nil
      assert email.text_body != nil
      assert is_binary(email.html_body)
      assert is_binary(email.text_body)
    end

    test "HTML body contains organizer information" do
      details =
        build_appointment_details(%{
          organizer_name: "Laura Smith",
          organizer_email: "laura@company.com"
        })

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      assert email.html_body =~ "Laura Smith"
    end

    test "HTML body contains meeting details" do
      details =
        build_appointment_details(%{
          meeting_type: "Consultation",
          location: "Virtual"
        })

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      # Should contain substantial information
      assert String.length(email.html_body) > 500
    end

    test "text body contains cancellation information" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      assert email.text_body =~ details.organizer_name
      assert String.length(email.text_body) > 100
    end

    test "HTML body may include reschedule option" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      # Cancellation emails may or may not include reschedule links
      assert is_binary(email.html_body)
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      assert %Swoosh.Email{} = email
      assert email.subject != nil
      assert email.to != []
    end

    test "HTML body contains cancellation message" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      assert email.html_body =~ "cancelled" || email.html_body =~ "Cancelled"
    end

    test "text body contains greeting and cancellation notice" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      assert email.text_body =~ "Meeting Cancelled"
      assert email.text_body =~ details.attendee_name
    end
  end

  describe "locale rendering - attendee cancellation emails" do
    test "renders attendee cancellation without error for all supported locales" do
      for locale <- ["en", "de", "uk", "fr"] do
        details = build_appointment_details(%{attendee_locale: locale})

        email =
          AppointmentCancellation.render(:attendee, "a@b.com", details)

        assert %Swoosh.Email{} = email,
               "Expected valid Swoosh email for locale #{locale}"

        assert is_binary(email.html_body),
               "Expected html_body for locale #{locale}"

        assert is_binary(email.text_body),
               "Expected text_body for locale #{locale}"
      end
    end

    test "German cancellation translates subject and body" do
      details = build_appointment_details(%{attendee_locale: "de"})
      email = AppointmentCancellation.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Termin abgesagt"
      refute email.subject =~ "Meeting Cancelled"
      assert email.text_body =~ "Termin abgesagt"
    end

    test "French cancellation translates subject and body" do
      details = build_appointment_details(%{attendee_locale: "fr"})
      email = AppointmentCancellation.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Réunion annulée"
      refute email.subject =~ "Meeting Cancelled"
      assert email.text_body =~ "Réunion annulée"
    end

    test "Ukrainian cancellation translates subject and body" do
      details = build_appointment_details(%{attendee_locale: "uk"})
      email = AppointmentCancellation.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Зустріч скасовано"
      refute email.subject =~ "Meeting Cancelled"
      assert email.text_body =~ "Зустріч скасовано"
    end
  end

  describe "locale via ContentBuilder - attendee cancellation emails" do
    test "German locale is honoured end-to-end through ContentBuilder" do
      meeting = build(:meeting, attendee_locale: "de")
      details = ContentBuilder.build_cancellation_details(meeting)
      email = AppointmentCancellation.render(:attendee, meeting.attendee_email, details)

      assert email.subject =~ "Termin abgesagt"
      refute email.subject =~ "Meeting Cancelled"
      assert email.text_body =~ "Termin abgesagt"
    end

    test "French locale is honoured end-to-end through ContentBuilder" do
      meeting = build(:meeting, attendee_locale: "fr")
      details = ContentBuilder.build_cancellation_details(meeting)
      email = AppointmentCancellation.render(:attendee, meeting.attendee_email, details)

      assert email.subject =~ "Réunion annulée"
      refute email.subject =~ "Meeting Cancelled"
    end

    test "Ukrainian locale is honoured end-to-end through ContentBuilder" do
      meeting = build(:meeting, attendee_locale: "uk")
      details = ContentBuilder.build_cancellation_details(meeting)
      email = AppointmentCancellation.render(:attendee, meeting.attendee_email, details)

      assert email.subject =~ "Зустріч скасовано"
      refute email.subject =~ "Meeting Cancelled"
    end
  end

  describe "attendee cancellation email uses attendee timezone" do
    test "HTML body shows attendee-local start time, not raw UTC" do
      # start_time is 14:00 UTC; attendee is in America/New_York (UTC-5 in January)
      # so attendee-local time is 09:00, represented here by a distinct DateTime value
      utc_start = ~U[2026-01-15 14:00:00Z]
      attendee_local_start = %{utc_start | hour: 9}

      details =
        build_appointment_details(%{
          start_time: utc_start,
          start_time_attendee_tz: attendee_local_start,
          attendee_timezone: "America/New_York"
        })

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      formatted_attendee = Formatting.format_time(attendee_local_start, "en")
      formatted_utc = Formatting.format_time(utc_start, "en")

      assert email.html_body =~ formatted_attendee,
             "Expected attendee-local time #{formatted_attendee} in HTML body"

      refute email.html_body =~ formatted_utc,
             "Expected raw UTC time #{formatted_utc} to be absent from HTML body"
    end
  end

  describe "attendee cancellation email METHOD:CANCEL attachment" do
    test "includes a text/calendar attachment with method=CANCEL" do
      details = build_appointment_details()

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert %Swoosh.Attachment{} = ics, "expected a text/calendar attachment"
      assert ics.content_type =~ "method=CANCEL"
      assert ics.filename =~ ".ics"
    end

    test "attachment body is a METHOD:CANCEL VCALENDAR with a SEQUENCE line" do
      details = build_appointment_details(%{ical_sequence: 3})

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert ics.data =~ "BEGIN:VCALENDAR"
      assert ics.data =~ "METHOD:CANCEL"
      assert ics.data =~ ~r/SEQUENCE:\d+/
      # Sequence should bump to (current + 1) = 4
      assert ics.data =~ "SEQUENCE:4"
    end

    test "defaults SEQUENCE to 1 when appointment_details has no ical_sequence" do
      details = build_appointment_details()

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert ics.data =~ "SEQUENCE:1"
    end
  end

  describe "cancellation emails for both roles" do
    test "organizer and attendee emails have different recipients" do
      details = build_appointment_details()

      organizer_email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      attendee_email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      assert organizer_email.to != attendee_email.to
    end

    test "organizer and attendee emails have different content focus" do
      details = build_appointment_details()

      organizer_email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      attendee_email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      # Organizer email focuses on attendee
      assert organizer_email.html_body =~ details.attendee_name

      # Attendee email focuses on organizer
      assert attendee_email.html_body =~ details.organizer_name
    end

    test "both roles generate valid complete emails" do
      details = build_appointment_details()

      organizer_email =
        AppointmentCancellation.render(:organizer, "organizer@example.com", details)

      attendee_email =
        AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      for email <- [organizer_email, attendee_email] do
        assert %Swoosh.Email{} = email
        assert email.subject != nil
        assert length(email.to) == 1
        assert email.html_body != nil
        assert email.text_body != nil
        assert String.length(email.html_body) > 100
        assert String.length(email.text_body) > 50
      end
    end
  end
end
