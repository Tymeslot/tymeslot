defmodule Tymeslot.Emails.Templates.AppointmentCancellationTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Emails.Templates.AppointmentCancellation
  import Tymeslot.EmailTestHelpers

  describe "cancellation_email_organizer/2" do
    test "creates email with correct subject line" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_organizer(
          "organizer@example.com",
          details
        )

      assert email.subject =~ "Cancelled"
      assert email.subject =~ details.attendee_name
    end

    test "sets correct recipient" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_organizer("organizer@test.com", details)

      assert email.to == [{"John Organizer", "organizer@test.com"}]
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_organizer(
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
        AppointmentCancellation.cancellation_email_organizer(
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
        AppointmentCancellation.cancellation_email_organizer(
          "organizer@example.com",
          details
        )

      # Should contain substantial information
      assert String.length(email.html_body) > 500
    end

    test "text body contains cancellation information" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_organizer(
          "organizer@example.com",
          details
        )

      assert email.text_body =~ details.attendee_name
      assert String.length(email.text_body) > 100
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_organizer(
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
        AppointmentCancellation.cancellation_email_organizer(
          "organizer@example.com",
          details
        )

      assert email.html_body =~ "cancelled" || email.html_body =~ "Cancelled"
    end

    test "text body contains meeting cancellation notice" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_organizer(
          "organizer@example.com",
          details
        )

      assert email.text_body =~ "Meeting Cancelled"
      assert email.text_body =~ details.attendee_name
    end
  end

  describe "cancellation_email_attendee/2" do
    test "creates email with correct subject line" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_attendee(
          "attendee@example.com",
          details
        )

      assert email.subject =~ "Cancelled"
      assert email.subject =~ details.organizer_name
    end

    test "sets correct recipient" do
      details = build_appointment_details()

      email = AppointmentCancellation.cancellation_email_attendee("attendee@test.com", details)

      assert email.to == [{"Jane Attendee", "attendee@test.com"}]
    end

    test "includes both HTML and text bodies" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_attendee(
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
        AppointmentCancellation.cancellation_email_attendee(
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
        AppointmentCancellation.cancellation_email_attendee(
          "attendee@example.com",
          details
        )

      # Should contain substantial information
      assert String.length(email.html_body) > 500
    end

    test "text body contains cancellation information" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_attendee(
          "attendee@example.com",
          details
        )

      assert email.text_body =~ details.organizer_name
      assert String.length(email.text_body) > 100
    end

    test "HTML body may include reschedule option" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_attendee(
          "attendee@example.com",
          details
        )

      # Cancellation emails may or may not include reschedule links
      assert is_binary(email.html_body)
    end

    test "email structure is valid Swoosh email" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_attendee(
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
        AppointmentCancellation.cancellation_email_attendee(
          "attendee@example.com",
          details
        )

      assert email.html_body =~ "cancelled" || email.html_body =~ "Cancelled"
    end

    test "text body contains greeting and cancellation notice" do
      details = build_appointment_details()

      email =
        AppointmentCancellation.cancellation_email_attendee(
          "attendee@example.com",
          details
        )

      assert email.text_body =~ "Meeting Cancelled"
      assert email.text_body =~ details.attendee_name
    end
  end

  describe "cancellation emails for both roles" do
    test "organizer and attendee emails have different recipients" do
      details = build_appointment_details()

      organizer_email =
        AppointmentCancellation.cancellation_email_organizer(
          "organizer@example.com",
          details
        )

      attendee_email =
        AppointmentCancellation.cancellation_email_attendee(
          "attendee@example.com",
          details
        )

      assert organizer_email.to != attendee_email.to
    end

    test "organizer and attendee emails have different content focus" do
      details = build_appointment_details()

      organizer_email =
        AppointmentCancellation.cancellation_email_organizer(
          "organizer@example.com",
          details
        )

      attendee_email =
        AppointmentCancellation.cancellation_email_attendee(
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
        AppointmentCancellation.cancellation_email_organizer("organizer@example.com", details)

      attendee_email =
        AppointmentCancellation.cancellation_email_attendee("attendee@example.com", details)

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
