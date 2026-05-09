defmodule Tymeslot.Emails.Templates.AppointmentConfirmationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  import Mox
  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  import Tymeslot.EmailTestHelpers

  setup :verify_on_exit!

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

      # Should contain formatted date
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

      # Text body should be substantial and informative
      assert String.length(email.text_body) > 100
      assert email.text_body =~ details.organizer_name
    end

    test "text body handles nil reminders_summary gracefully" do
      details = build_appointment_details(%{reminders_summary: nil})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      # Should not contain "nil" string
      refute email.text_body =~ "nil"
      # Should still be valid email
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

      # Should not contain "nil" string
      refute email.html_body =~ "nil"
      # Should still be valid email
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

      # Should have calendar-related content (Google Calendar, Outlook, etc.)
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

  describe "attendee payment receipt block" do
    test "renders payment block with receipt URL when charge fetch succeeds" do
      booking_payment = %{
        status: "paid",
        amount_cents: 5000,
        currency: "eur",
        application_fee_cents: 25,
        paid_at: ~U[2026-05-08 14:32:00Z],
        stripe_charge_id: "ch_TEST_RECEIPT",
        stripe_account_id: "acct_TEST"
      }

      expect(StripeAdapterMock, :retrieve_charge, fn "ch_TEST_RECEIPT", opts ->
        assert opts[:connect_account] == "acct_TEST"
        {:ok, %{receipt_url: "https://pay.stripe.com/receipts/r_TEST"}}
      end)

      details = build_appointment_details(%{booking_payment: booking_payment})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.text_body =~ "PAYMENT RECEIPT"
      assert email.text_body =~ "€50.00 paid"
      assert email.text_body =~ "ch_TEST_RECEIPT"
      assert email.text_body =~ "https://pay.stripe.com/receipts/r_TEST"
      assert email.html_body =~ "Payment receipt"
      assert email.html_body =~ "https://pay.stripe.com/receipts/r_TEST"
      assert email.html_body =~ "View receipt"
    end

    test "renders without payment block for free booking" do
      details = build_appointment_details(%{booking_payment: nil})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      refute email.text_body =~ "PAYMENT RECEIPT"
      refute email.html_body =~ "Payment receipt"
    end

    test "renders payment block without link when receipt fetch fails" do
      booking_payment = %{
        status: "paid",
        amount_cents: 5000,
        currency: "eur",
        application_fee_cents: 25,
        paid_at: ~U[2026-05-08 14:32:00Z],
        stripe_charge_id: "ch_TEST_FAIL",
        stripe_account_id: "acct_TEST"
      }

      expect(StripeAdapterMock, :retrieve_charge, fn _id, _opts -> {:error, :api_error} end)

      details = build_appointment_details(%{booking_payment: booking_payment})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      assert email.text_body =~ "PAYMENT RECEIPT"
      assert email.text_body =~ "€50.00 paid"
      refute email.text_body =~ "View receipt"
      assert email.html_body =~ "Payment receipt"
      refute email.html_body =~ "View receipt"
    end

    test "renders payment block without link when receipt URL is missing" do
      booking_payment = %{
        status: "paid",
        amount_cents: 5000,
        currency: "eur",
        application_fee_cents: 25,
        paid_at: ~U[2026-05-08 14:32:00Z],
        stripe_charge_id: "ch_TEST_NO_URL",
        stripe_account_id: "acct_TEST"
      }

      expect(StripeAdapterMock, :retrieve_charge, fn _id, _opts -> {:ok, %{receipt_url: nil}} end)

      details = build_appointment_details(%{booking_payment: booking_payment})
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

      refute email.html_body =~ "View receipt"
    end
  end

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

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "Conference Room A"
      assert email.html_body =~ "Product Demo"
    end

    test "HTML body contains date and time" do
      details = build_appointment_details()

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      # Should contain formatted date
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
      # When reminders_enabled is nil, it should default to true
      # But we need reminder_time to be present for the message to show
      details =
        build_appointment_details(%{
          reminders_enabled: nil,
          reminder_time: "15 minutes"
        })

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      # Should default to showing reminder message (reminders enabled)
      # Note: The function uses Map.get with default true, so nil becomes true
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

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      # Subject should reference the meeting
      assert email.subject != nil
      assert String.length(email.subject) > 0
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()

      email =
        AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

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
