defmodule Tymeslot.Emails.Templates.AppointmentCancellationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Emails.Templates.AppointmentCancellation
  alias Tymeslot.Notifications.ContentBuilder
  alias TymeslotWeb.Endpoint
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

      assert email.html_body =~ "</html>"

      assert email.html_body =~
               "The appointment with #{details.attendee_name} has been cancelled."

      assert email.text_body =~
               "The appointment with #{details.attendee_name} has been cancelled."

      refute email.text_body =~ "</html>"
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
          location: "Head Office"
        })

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      assert email.html_body =~ "Product Demo"
      assert email.html_body =~ "Head Office"
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
      assert email.subject =~ "Meeting Cancelled"
      assert email.to == [{details.organizer_name, "organizer@example.com"}]
    end

    test "HTML body contains cancellation notification" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      assert email.html_body =~ "Meeting cancelled"
      assert email.html_body =~ "The attendee has been notified of the cancellation."
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

    test "does not claim the organiser's calendar was updated (regression for d56cf8677)" do
      # d56cf8677 removed the stale "Your calendar has been updated to
      # reflect this cancellation." line from the organiser cancellation
      # email — no ICS cancel attachment is sent, so the claim would
      # have misled the organiser into thinking their calendar software
      # had processed the cancellation. Both bodies must stay clear of
      # that phrase.
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :organizer,
          "organizer@example.com",
          details
        )

      refute email.html_body =~ "calendar has been updated"
      refute email.text_body =~ "calendar has been updated"
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

      assert email.html_body =~ "</html>"
      assert email.html_body =~ "our appointment has been cancelled"

      assert email.text_body =~
               "We're writing to confirm that your appointment has been cancelled."

      refute email.text_body =~ "</html>"
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

      assert email.html_body =~ "Consultation"
      assert email.html_body =~ "Virtual"
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

    test "HTML body invites the attendee to book a new appointment" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      assert email.html_body =~ "Would you like to schedule a new appointment?"
      assert email.html_body =~ "Schedule New Appointment"
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
      assert email.subject =~ "Meeting Cancelled"
      assert email.to == [{details.attendee_name, "attendee@example.com"}]
    end

    test "HTML body contains cancellation message" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          details
        )

      assert email.html_body =~ "Meeting cancelled"
      assert email.html_body =~ "This time slot is now available for booking again."
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

  # Regression: the "Schedule New Appointment" CTA used to be hardcoded to the
  # bare application root, so the attendee landed on the landing page instead of
  # a page where they could book again. See issue #90.
  describe "attendee cancellation email booking CTA" do
    test "button links to the host's booking page rather than the app root" do
      details = build_appointment_details(%{booking_url: "https://tymeslot.example.com/sarah"})

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      assert cta_href(email.html_body) == "https://tymeslot.example.com/sarah"
    end

    test "text body links to the host's booking page rather than the app root" do
      details = build_appointment_details(%{booking_url: "https://tymeslot.example.com/sarah"})

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      assert email.text_body =~ "https://tymeslot.example.com/sarah"
    end

    test "falls back to the app root when the details carry no booking URL" do
      details = Map.delete(build_appointment_details(), :booking_url)

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      assert cta_href(email.html_body) == Endpoint.url()
    end
  end

  # The footer wordmark also links to the app root, so the CTA has to be located
  # by its own label rather than by scanning every href in the document.
  defp cta_href(html_body) do
    [_full, href] =
      Regex.run(~r/<a href="([^"]+)"[^>]*>\s*Schedule New Appointment\s*<\/a>/s, html_body)

    href
  end

  describe "locale rendering - attendee cancellation emails" do
    test "renders attendee cancellation without error for all supported locales" do
      for locale <- ["en", "de", "uk", "fr", "it"] do
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

    test "Italian cancellation translates subject and body" do
      details = build_appointment_details(%{attendee_locale: "it"})
      email = AppointmentCancellation.render(:attendee, "a@b.com", details)

      assert email.subject =~ "Riunione annullata"
      refute email.subject =~ "Meeting Cancelled"
      assert email.text_body =~ "Riunione annullata"
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

  # The attendee cancellation email used to advertise METHOD:CANCEL via both
  # the content-type and the VCALENDAR body, which caused recipient mail
  # servers (Zimbra, Nextcloud, iCloud Mail) to auto-process the attachment
  # as an iTIP cancellation and fire an extra round of notifications. We
  # now emit METHOD:PUBLISH + STATUS:CANCELLED instead — clients still see
  # the event as cancelled, but MTAs leave it alone. See issue #41.
  describe "attendee cancellation email ICS attachment" do
    test "includes a text/calendar attachment with method=PUBLISH" do
      details = build_appointment_details()

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert %Swoosh.Attachment{} = ics, "expected a text/calendar attachment"
      assert ics.content_type =~ "method=PUBLISH"
      refute ics.content_type =~ "method=CANCEL"
      assert ics.filename =~ ".ics"
    end

    test "attachment body conveys cancellation via STATUS:CANCELLED with a SEQUENCE line" do
      details = build_appointment_details(%{ical_sequence: 3})

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert ics.data =~ "BEGIN:VCALENDAR"
      assert ics.data =~ "METHOD:PUBLISH"
      refute ics.data =~ "METHOD:CANCEL"
      assert ics.data =~ "STATUS:CANCELLED"
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

    # Issue #41: defence-in-depth — even with METHOD:PUBLISH, tagging
    # ORGANIZER/ATTENDEE with SCHEDULE-AGENT=CLIENT prevents any remaining
    # scheduling-aware server from re-routing the attachment as an iTIP
    # cancellation.
    test "ORGANIZER and ATTENDEE lines carry SCHEDULE-AGENT=CLIENT" do
      details = build_appointment_details()

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      ics = Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert ics.data =~ ~r/^ORGANIZER;SCHEDULE-AGENT=CLIENT[;:]/m
      assert ics.data =~ ~r/^ATTENDEE;SCHEDULE-AGENT=CLIENT[;:]/m
    end
  end

  describe "subject CRLF injection prevention" do
    test "attendee subject is free of CR/LF when organizer name contains header-injection payload" do
      details =
        build_appointment_details(%{
          organizer_name: "Alice\r\nBcc: attacker@evil.com"
        })

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      refute email.subject =~ "\r"
      refute email.subject =~ "\n"
    end

    test "organizer subject is free of CR/LF when attendee name contains header-injection payload" do
      details =
        build_appointment_details(%{
          attendee_name: "Bob\r\nCc: someone@evil.com"
        })

      email = AppointmentCancellation.render(:organizer, "organizer@example.com", details)

      refute email.subject =~ "\r"
      refute email.subject =~ "\n"
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
        assert email.subject =~ "Meeting Cancelled"
        assert length(email.to) == 1
        assert email.html_body =~ "Meeting cancelled"
        assert email.text_body =~ "Meeting Cancelled"
        assert String.length(email.html_body) > 100
        assert String.length(email.text_body) > 50
      end
    end
  end
end
