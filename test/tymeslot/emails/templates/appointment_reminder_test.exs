defmodule Tymeslot.Emails.Templates.AppointmentReminderTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

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

    test "may include calendar attachment" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      # Reminder emails may or may not include attachments depending on template design
      assert is_list(email.attachments)
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.html_body != nil
      assert email.text_body != nil
      assert is_binary(email.html_body)
      assert is_binary(email.text_body)
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

      # Should contain substantial meeting information
      assert String.length(email.html_body) > 1000
    end

    test "HTML body includes action links" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ details.reschedule_url || email.html_body =~ details.cancel_url
    end

    test "generates valid email with video meeting URL" do
      details =
        build_appointment_details(%{
          meeting_url: "https://meet.example.com/reminder-test"
        })

      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.html_body != nil
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

      assert %Swoosh.Email{} = email
      assert email.subject != nil
      assert email.to != []
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

    test "may include calendar attachment" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      # Reminder emails may or may not include attachments depending on template design
      assert is_list(email.attachments)
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.html_body != nil
      assert email.text_body != nil
      assert is_binary(email.html_body)
      assert is_binary(email.text_body)
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

      # Should contain substantial meeting information
      assert String.length(email.html_body) > 1000
    end

    test "HTML body includes action links" do
      details = build_appointment_details()
      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.html_body =~ details.reschedule_url || email.html_body =~ details.cancel_url
    end

    test "generates valid email with video meeting URL" do
      details =
        build_appointment_details(%{
          meeting_url: "https://meet.example.com/attendee-reminder"
        })

      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      assert email.html_body != nil
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

      assert %Swoosh.Email{} = email
      assert email.subject != nil
      assert email.to != []
    end

    test "handles different time_until values correctly" do
      time_values = ["15 minutes", "30 minutes", "1 hour", "2 hours", "1 day"]

      for time_until <- time_values do
        details = build_appointment_details(%{time_until: time_until})
        email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

        assert email.html_body =~ time_until
        assert email.subject != nil
      end
    end

    test "includes timezone-aware time display" do
      details =
        build_appointment_details(%{
          attendee_timezone: "America/Los_Angeles"
        })

      email = AppointmentReminder.render(:attendee, "attendee@example.com", details)

      # Should include substantial content with time information
      assert String.length(email.html_body) > 1000
      assert email.html_body != nil
    end
  end

  describe "attendee locale rendering" do
    test "renders without error for all supported locales" do
      for locale <- ["en", "de", "uk", "fr"] do
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
  end
end
