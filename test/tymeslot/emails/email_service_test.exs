defmodule Tymeslot.Emails.EmailServiceTest do
  # async: false is required: `Swoosh.Adapters.Test` delivers to whichever
  # process calls `Mailer.deliver/1`, and every send here runs inside the email
  # circuit-breaker GenServer rather than the test process. Pointing Swoosh's
  # `:shared_test_process` at this test is what makes the delivered messages
  # observable, and that setting is global, so no other test may run alongside.
  use Tymeslot.DataCase, async: false
  @moduletag :emails

  import Tymeslot.EmailTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Emails.EmailService

  alias Tymeslot.Emails.Templates.{
    AppointmentCancellation,
    AppointmentConfirmation,
    AppointmentReminder
  }

  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    :ok
  end

  # Returns the next delivered email, failing the test if none was delivered.
  # These tests care about *which* message went to *whom*, so they read the
  # mailbox in order rather than searching it.
  defp next_email do
    assert_received {:email, email}
    email
  end

  defp assert_no_more_emails do
    refute_received {:email, _email}
  end

  describe "send_appointment_confirmations/1" do
    test "sends the organizer variant to the organizer and the attendee variant to the attendee" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_appointment_confirmations(details)

      assert {:ok, _response} = org_result
      assert {:ok, _response} = att_result

      organizer = next_email()
      assert organizer.to == [{"John Organizer", "organizer@example.com"}]
      assert organizer.subject == "New Appointment: Jane Attendee - Jan 15"

      attendee = next_email()
      assert attendee.to == [{"Jane Attendee", "attendee@example.com"}]
      assert attendee.subject == "Appointment Confirmed - Jan 15 with John Organizer"

      assert_no_more_emails()
    end
  end

  describe "send_appointment_reminders/1" do
    test "sends both reminders with the default time_until" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_appointment_reminders(details)

      assert {:ok, _response} = org_result
      assert {:ok, _response} = att_result

      organizer = next_email()
      assert organizer.to == [{"John Organizer", "organizer@example.com"}]
      assert organizer.subject =~ "in 30 minutes"

      attendee = next_email()
      assert attendee.to == [{"Jane Attendee", "attendee@example.com"}]
      assert attendee.subject =~ "30 minutes"

      assert_no_more_emails()
    end

    test "a custom time_until reaches both subjects" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_appointment_reminders(details, "1 hour")

      assert {:ok, _response} = org_result
      assert {:ok, _response} = att_result

      assert next_email().subject =~ "in 1 hour"
      assert next_email().subject =~ "1 hour"
      assert_no_more_emails()
    end
  end

  describe "send_cancellation_emails/1" do
    test "tells each party the meeting is cancelled, naming the other one" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_cancellation_emails(details)

      assert {:ok, _response} = org_result
      assert {:ok, _response} = att_result

      organizer = next_email()
      assert organizer.to == [{"John Organizer", "organizer@example.com"}]
      assert organizer.subject == "Meeting Cancelled - Jan 15 with Jane Attendee"

      attendee = next_email()
      assert attendee.to == [{"Jane Attendee", "attendee@example.com"}]
      assert attendee.subject == "Meeting Cancelled - Jan 15 with John Organizer"

      assert_no_more_emails()
    end
  end

  describe "send_appointment_cancellation/2" do
    test "routes to the organizer variant when the address is the organizer's" do
      details = build_appointment_details(%{organizer_email: "organizer@example.com"})

      assert {:ok, _response} =
               EmailService.send_appointment_cancellation("organizer@example.com", details)

      email = next_email()
      assert email.to == [{"John Organizer", "organizer@example.com"}]
      # The organizer's copy names the attendee; the attendee's names the organizer.
      assert email.subject == "Meeting Cancelled - Jan 15 with Jane Attendee"
      assert_no_more_emails()
    end

    test "routes to the attendee variant for any other address" do
      details = build_appointment_details(%{attendee_email: "attendee@example.com"})

      assert {:ok, _response} =
               EmailService.send_appointment_cancellation("attendee@example.com", details)

      email = next_email()
      assert email.to == [{"Jane Attendee", "attendee@example.com"}]
      assert email.subject == "Meeting Cancelled - Jan 15 with John Organizer"
      assert_no_more_emails()
    end
  end

  describe "send_email_verification/2" do
    test "sends the verification link to the user's address" do
      user = build_user_data(%{email: "user@example.com", name: "Test User"})
      verification_url = "https://example.com/verify/token123"

      assert {:ok, _response} = EmailService.send_email_verification(user, verification_url)

      email = next_email()
      assert email.to == [{"Test User", "user@example.com"}]
      assert email.subject == "Verify your email address"
      assert email.html_body =~ verification_url
      assert email.text_body =~ verification_url
    end
  end

  describe "send_password_reset/2" do
    test "sends the reset link to the user's address" do
      user = build_user_data(%{email: "reset@example.com"})
      reset_url = "https://example.com/reset/token456"

      assert {:ok, _response} = EmailService.send_password_reset(user, reset_url)

      email = next_email()
      assert email.to == [{"Test User", "reset@example.com"}]
      assert email.subject == "Reset your password"
      assert email.html_body =~ reset_url
      assert email.text_body =~ reset_url
    end
  end

  describe "send_email_change_verification/3" do
    test "sends the verification to the new address, never the current one" do
      user = build_user_data(%{email: "old@example.com"})
      verification_url = "https://example.com/verify-change/token"

      assert {:ok, _response} =
               EmailService.send_email_change_verification(
                 user,
                 "new@example.com",
                 verification_url
               )

      email = next_email()
      assert email.to == [{"Test User", "new@example.com"}]
      assert email.subject == "Verify your new email address"
      assert email.html_body =~ verification_url
      assert_no_more_emails()
    end
  end

  describe "send_email_change_notification/2" do
    test "warns the old address that a change was requested" do
      user = build_user_data(%{email: "old@example.com"})

      assert {:ok, _response} =
               EmailService.send_email_change_notification(user, "new@example.com")

      email = next_email()
      assert email.to == [{"Test User", "old@example.com"}]
      assert email.subject =~ "Email Change Request"
      assert_no_more_emails()
    end
  end

  describe "send_email_change_confirmations/3" do
    test "confirms to the old address first, then the new one" do
      user = build_user_data()

      {old_result, new_result} =
        EmailService.send_email_change_confirmations(user, "old@example.com", "new@example.com")

      assert {:ok, _response} = old_result
      assert {:ok, _response} = new_result

      old = next_email()
      assert old.to == [{"Test User", "old@example.com"}]
      assert old.subject == "Email Address Changed - Tymeslot Account"

      new = next_email()
      assert new.to == [{"Test User", "new@example.com"}]
      assert new.subject == "Email Address Changed Successfully"

      assert_no_more_emails()
    end
  end

  describe "send_calendar_invitation/2" do
    test "sends the invitation to the address given, not to a detail field" do
      details = build_invitation_details()

      assert {:ok, _response} =
               EmailService.send_calendar_invitation("attendee@example.com", details)

      email = next_email()
      assert email.to == [{"", "attendee@example.com"}]
      assert email.subject =~ "Calendar Invitation - Test Event"
      assert_no_more_emails()
    end

    test "carries the custom title and location through, with an .ics attached" do
      details =
        build_invitation_details(%{
          event_title: "Team Standup",
          location: "Conference Room B",
          description: "Weekly sync"
        })

      assert {:ok, _response} =
               EmailService.send_calendar_invitation("colleague@example.com", details)

      email = next_email()
      assert email.to == [{"", "colleague@example.com"}]
      assert email.subject =~ "Team Standup"
      assert email.html_body =~ "Conference Room B"
      assert email.text_body =~ "Conference Room B"

      # The description reaches the guest through the calendar file, not the body.
      assert Enum.any?(email.attachments, &String.ends_with?(&1.filename, ".ics"))
    end
  end

  describe "template integration" do
    test "organizer confirmation template creates a valid Swoosh email" do
      details = build_appointment_details()

      org_email =
        AppointmentConfirmation.render(:organizer, details.organizer_email, details)

      assert %Swoosh.Email{} = org_email
      assert org_email.to == [{"John Organizer", "organizer@example.com"}]
      assert org_email.subject == "New Appointment: Jane Attendee - Jan 15"
    end

    test "attendee confirmation template creates a valid Swoosh email" do
      details = build_appointment_details()

      att_email =
        AppointmentConfirmation.render(:attendee, details.attendee_email, details)

      assert %Swoosh.Email{} = att_email
      assert att_email.to == [{"Jane Attendee", "attendee@example.com"}]
      assert att_email.subject == "Appointment Confirmed - Jan 15 with John Organizer"
    end

    test "reminder templates address each party with their own subject" do
      details = build_appointment_details()

      org_email = AppointmentReminder.render(:organizer, details.organizer_email, details)
      att_email = AppointmentReminder.render(:attendee, details.attendee_email, details)

      assert org_email.to == [{"John Organizer", "organizer@example.com"}]
      assert org_email.subject =~ "Meeting with Jane Attendee in 30 minutes"

      assert att_email.to == [{"Jane Attendee", "attendee@example.com"}]
      assert att_email.subject == "Reminder: Our meeting is 30 minutes"
    end

    test "cancellation templates address each party with their own subject" do
      details = build_appointment_details()

      org_email =
        AppointmentCancellation.render(:organizer, details.organizer_email, details)

      att_email =
        AppointmentCancellation.render(:attendee, details.attendee_email, details)

      assert org_email.to == [{"John Organizer", "organizer@example.com"}]
      assert org_email.subject == "Meeting Cancelled - Jan 15 with Jane Attendee"

      assert att_email.to == [{"Jane Attendee", "attendee@example.com"}]
      assert att_email.subject == "Meeting Cancelled - Jan 15 with John Organizer"
    end
  end

  describe "send_external_booking_change/3" do
    test "tells the organizer the booking was deleted externally" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert {:ok, _response} =
               EmailService.send_external_booking_change(
                 meeting,
                 meeting.organizer_email,
                 :deleted
               )

      email = next_email()
      assert [{_name, address}] = email.to
      assert address == meeting.organizer_email
      assert email.subject =~ "was deleted from your external calendar"
      assert_no_more_emails()
    end

    test "tells the organizer the booking was rescheduled externally" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert {:ok, _response} =
               EmailService.send_external_booking_change(
                 meeting,
                 meeting.organizer_email,
                 :modified
               )

      email = next_email()
      assert [{_name, address}] = email.to
      assert address == meeting.organizer_email
      assert email.subject =~ "was rescheduled in your external calendar"
      assert_no_more_emails()
    end
  end

  describe "send_event_update_notification/2" do
    test "sends the update to the address given" do
      details = build_event_update_details()

      assert {:ok, _response} =
               EmailService.send_event_update_notification("attendee@example.com", details)

      email = next_email()
      assert email.to == [{"", "attendee@example.com"}]
      assert email.subject =~ "Updated Event"
      assert_no_more_emails()
    end

    test "names the new title and lists every change" do
      # `:title` and `:location` are two of the four change kinds the templates
      # know how to render; anything else is dropped silently.
      details =
        build_event_update_details(%{
          event_title: "Rescheduled Standup",
          changes: [
            {:location, "Room A", "Room C"},
            {:title, "Daily Standup", "Rescheduled Standup"}
          ]
        })

      assert {:ok, _response} =
               EmailService.send_event_update_notification("colleague@example.com", details)

      email = next_email()
      assert email.to == [{"", "colleague@example.com"}]
      assert email.subject =~ "Rescheduled Standup"
      assert email.text_body =~ "Location: Room A → Room C"
      assert email.text_body =~ "Title: Daily Standup → Rescheduled Standup"
      assert email.html_body =~ "Room C"
    end
  end

  describe "send_integration_unhealthy_notification/3" do
    test "names the calendar integration in the subject" do
      user = build_user_data(%{email: "owner@example.com", name: "Integration Owner"})
      integration = %{id: System.unique_integer([:positive]), provider: :google}

      assert {:ok, _response} =
               EmailService.send_integration_unhealthy_notification(user, integration, :calendar)

      email = next_email()
      assert email.to == [{"Integration Owner", "owner@example.com"}]
      assert email.subject == "Your calendar integration may need attention"
      assert_no_more_emails()
    end

    test "names the video integration in the subject" do
      user = build_user_data(%{email: "owner@example.com"})
      integration = %{id: System.unique_integer([:positive]), provider: :zoom}

      assert {:ok, _response} =
               EmailService.send_integration_unhealthy_notification(user, integration, :video)

      email = next_email()
      assert email.to == [{"Test User", "owner@example.com"}]
      assert email.subject == "Your video integration may need attention"
      assert_no_more_emails()
    end
  end

  describe "send_reschedule_request/1" do
    test "asks the attendee, not the organizer, to pick a new time" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert {:ok, _response} = EmailService.send_reschedule_request(meeting)

      email = next_email()
      assert [{_name, address}] = email.to
      assert address == meeting.attendee_email
      assert email.subject =~ "Reschedule Request: #{meeting.title}"
      assert_no_more_emails()
    end
  end
end
