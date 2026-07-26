defmodule Tymeslot.Emails.EmailServiceTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  import Tymeslot.EmailTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Emails.EmailService

  alias Tymeslot.Emails.Templates.{
    AppointmentCancellation,
    AppointmentConfirmation,
    AppointmentReminder
  }

  describe "send_appointment_confirmations/1" do
    test "sends emails to both organizer and attendee" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_appointment_confirmations(details)

      assert match?({:ok, _}, org_result)
      assert match?({:ok, _}, att_result)
    end
  end

  describe "send_appointment_reminders/1" do
    test "sends reminder emails to both organizer and attendee with default time" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_appointment_reminders(details)

      assert match?({:ok, _}, org_result)
      assert match?({:ok, _}, att_result)
    end

    test "accepts custom time_until parameter" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_appointment_reminders(details, "1 hour")

      assert match?({:ok, _}, org_result)
      assert match?({:ok, _}, att_result)
    end
  end

  describe "send_cancellation_emails/1" do
    test "sends cancellation emails to both organizer and attendee" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_cancellation_emails(details)

      assert match?({:ok, _}, org_result)
      assert match?({:ok, _}, att_result)
    end
  end

  describe "send_appointment_cancellation/2" do
    test "sends to organizer when email matches organizer_email" do
      details = build_appointment_details(%{organizer_email: "organizer@example.com"})

      result = EmailService.send_appointment_cancellation("organizer@example.com", details)

      # Should return ok tuple (emails successfully sent in test environment)
      assert match?({:ok, _}, result)
    end

    test "sends to attendee when email matches attendee_email" do
      details = build_appointment_details(%{attendee_email: "attendee@example.com"})

      result = EmailService.send_appointment_cancellation("attendee@example.com", details)

      assert match?({:ok, _}, result)
    end
  end

  describe "send_email_verification/2" do
    test "sends verification email" do
      user = build_user_data(%{email: "user@example.com", name: "Test User"})
      verification_url = "https://example.com/verify/token123"

      result = EmailService.send_email_verification(user, verification_url)

      assert match?({:ok, _}, result)
    end
  end

  describe "send_password_reset/2" do
    test "sends password reset email" do
      user = build_user_data(%{email: "reset@example.com"})
      reset_url = "https://example.com/reset/token456"

      result = EmailService.send_password_reset(user, reset_url)

      assert match?({:ok, _}, result)
    end
  end

  describe "send_email_change_verification/3" do
    test "sends verification to new email address" do
      user = build_user_data(%{email: "old@example.com"})
      new_email = "new@example.com"
      verification_url = "https://example.com/verify-change/token"

      result = EmailService.send_email_change_verification(user, new_email, verification_url)

      assert match?({:ok, _}, result)
    end
  end

  describe "send_email_change_notification/2" do
    test "sends notification to old email address" do
      user = build_user_data(%{email: "old@example.com"})
      new_email = "new@example.com"

      result = EmailService.send_email_change_notification(user, new_email)

      assert match?({:ok, _}, result)
    end
  end

  describe "send_email_change_confirmations/3" do
    test "sends confirmation to both old and new email addresses" do
      user = build_user_data()
      old_email = "old@example.com"
      new_email = "new@example.com"

      {old_result, new_result} =
        EmailService.send_email_change_confirmations(user, old_email, new_email)

      assert match?({:ok, _}, old_result)
      assert match?({:ok, _}, new_result)
    end
  end

  describe "send_calendar_invitation/2" do
    test "sends calendar invitation email" do
      details = build_invitation_details()

      result = EmailService.send_calendar_invitation("attendee@example.com", details)

      assert {:ok, _response} = result
    end

    test "sends calendar invitation with custom details" do
      details =
        build_invitation_details(%{
          event_title: "Team Standup",
          location: "Conference Room B",
          description: "Weekly sync"
        })

      result = EmailService.send_calendar_invitation("colleague@example.com", details)

      assert {:ok, _response} = result
    end
  end

  describe "template integration" do
    test "organizer confirmation template creates a valid Swoosh email" do
      details = build_appointment_details()

      org_email =
        AppointmentConfirmation.render(:organizer, details.organizer_email, details)

      assert %Swoosh.Email{} = org_email
      assert org_email.subject == "New Appointment: Jane Attendee - Jan 15"
    end

    test "attendee confirmation template creates a valid Swoosh email" do
      details = build_appointment_details()

      att_email =
        AppointmentConfirmation.render(:attendee, details.attendee_email, details)

      assert %Swoosh.Email{} = att_email
      assert att_email.subject == "Appointment Confirmed - Jan 15 with John Organizer"
    end

    test "reminder templates create valid Swoosh emails" do
      details = build_appointment_details()

      org_email = AppointmentReminder.render(:organizer, details.organizer_email, details)
      att_email = AppointmentReminder.render(:attendee, details.attendee_email, details)

      assert %Swoosh.Email{} = org_email
      assert %Swoosh.Email{} = att_email
    end

    test "cancellation templates create valid Swoosh emails" do
      details = build_appointment_details()

      org_email =
        AppointmentCancellation.render(:organizer, details.organizer_email, details)

      att_email =
        AppointmentCancellation.render(:attendee, details.attendee_email, details)

      assert %Swoosh.Email{} = org_email
      assert %Swoosh.Email{} = att_email
    end
  end

  describe "send_external_booking_change/3" do
    test "returns ok tuple for :deleted discrepancy" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      result =
        EmailService.send_external_booking_change(
          meeting,
          meeting.organizer_email,
          :deleted
        )

      assert {:ok, _response} = result
    end

    test "returns ok tuple for :modified discrepancy" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      result =
        EmailService.send_external_booking_change(
          meeting,
          meeting.organizer_email,
          :modified
        )

      assert {:ok, _response} = result
    end
  end

  describe "send_event_update_notification/2" do
    test "returns ok tuple with valid update details" do
      details = build_event_update_details()

      result =
        EmailService.send_event_update_notification("attendee@example.com", details)

      assert {:ok, _response} = result
    end

    test "returns ok tuple with custom changes" do
      details =
        build_event_update_details(%{
          event_title: "Rescheduled Standup",
          changes: [{:location, "Room A", "Room C"}, {:start_time, "09:00", "10:00"}]
        })

      result =
        EmailService.send_event_update_notification("colleague@example.com", details)

      assert {:ok, _response} = result
    end
  end

  describe "send_integration_unhealthy_notification/3" do
    test "returns ok tuple for calendar integration" do
      user = build_user_data(%{email: "owner@example.com", name: "Integration Owner"})

      integration = %{
        id: System.unique_integer([:positive]),
        provider: :google
      }

      result =
        EmailService.send_integration_unhealthy_notification(user, integration, :calendar)

      assert {:ok, _response} = result
    end

    test "returns ok tuple for video integration" do
      user = build_user_data(%{email: "owner@example.com"})

      integration = %{
        id: System.unique_integer([:positive]),
        provider: :zoom
      }

      result =
        EmailService.send_integration_unhealthy_notification(user, integration, :video)

      assert {:ok, _response} = result
    end
  end

  describe "send_reschedule_request/1" do
    test "returns ok tuple for a valid meeting" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      result = EmailService.send_reschedule_request(meeting)

      assert {:ok, _response} = result
    end
  end
end
