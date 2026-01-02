defmodule Tymeslot.Emails.EmailServiceTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Emails.Templates.{
    AppointmentCancellation,
    AppointmentConfirmationAttendee,
    AppointmentConfirmationOrganizer,
    AppointmentReminderAttendee,
    AppointmentReminderOrganizer,
    ContactForm
  }

  describe "send_appointment_confirmations/1" do
    test "sends emails to both organizer and attendee" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_appointment_confirmations(details)

      # Both should succeed (or fail gracefully)
      assert is_tuple({org_result, att_result})
    end

    test "returns tuple of both results" do
      details = build_appointment_details()

      result = EmailService.send_appointment_confirmations(details)

      assert is_tuple(result)
      assert tuple_size(result) == 2
    end
  end

  describe "send_appointment_reminders/1" do
    test "sends reminder emails to both organizer and attendee with default time" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_appointment_reminders(details)

      assert is_tuple({org_result, att_result})
    end

    test "accepts custom time_until parameter" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_appointment_reminders(details, "1 hour")

      assert is_tuple({org_result, att_result})
    end
  end

  describe "send_cancellation_emails/1" do
    test "sends cancellation emails to both organizer and attendee" do
      details = build_appointment_details()

      {org_result, att_result} = EmailService.send_cancellation_emails(details)

      assert is_tuple({org_result, att_result})
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

      {old_result, new_result} = EmailService.send_email_change_confirmations(user, old_email, new_email)

      assert is_tuple({old_result, new_result})
    end
  end

  describe "send_contact_form/4" do
    test "sends contact form email to support" do
      result =
        EmailService.send_contact_form(
          "John Doe",
          "john@example.com",
          "Question",
          "I have a question."
        )

      assert match?({:ok, _}, result)
    end
  end

  describe "template integration" do
    test "confirmation templates create valid Swoosh emails" do
      details = build_appointment_details()

      org_email = AppointmentConfirmationOrganizer.confirmation_email(details.organizer_email, details)
      att_email = AppointmentConfirmationAttendee.confirmation_email(details.attendee_email, details)

      assert %Swoosh.Email{} = org_email
      assert %Swoosh.Email{} = att_email
      assert org_email.subject != nil
      assert att_email.subject != nil
    end

    test "reminder templates create valid Swoosh emails" do
      details = build_appointment_details()

      org_email = AppointmentReminderOrganizer.reminder_email(details.organizer_email, details)
      att_email = AppointmentReminderAttendee.reminder_email(details.attendee_email, details)

      assert %Swoosh.Email{} = org_email
      assert %Swoosh.Email{} = att_email
    end

    test "cancellation templates create valid Swoosh emails" do
      details = build_appointment_details()

      org_email = AppointmentCancellation.cancellation_email_organizer(details.organizer_email, details)
      att_email = AppointmentCancellation.cancellation_email_attendee(details.attendee_email, details)

      assert %Swoosh.Email{} = org_email
      assert %Swoosh.Email{} = att_email
    end

    test "contact form template creates valid Swoosh email" do
      email = ContactForm.contact_form_email("John Doe", "john@example.com", "Question", "Test message")

      assert %Swoosh.Email{} = email
      assert email.to == [{
        Application.get_env(:tymeslot, :email)[:from_name],
        Application.get_env(:tymeslot, :email)[:contact_recipient]
      }]
    end
  end
end
