defmodule Tymeslot.Workers.EmailWorkerHandlersTest do
  use Tymeslot.DataCase, async: true
  import Mox
  import Tymeslot.Factory
  alias Ecto.UUID
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Workers.EmailWorkerHandlers

  setup :verify_on_exit!

  describe "execute_email_action/2" do
    test "discards unknown actions" do
      assert {:discard, "Unknown action: unknown"} =
               EmailWorkerHandlers.execute_email_action("unknown", %{})
    end

    test "handles send_confirmation_emails" do
      meeting = insert(:meeting)
      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _, _ -> {:ok, "sent"} end)
      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _, _ -> {:ok, "sent"} end)

      assert :ok = EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{"meeting_id" => meeting.id})
    end

    test "handles send_reminder_emails" do
      meeting = insert(:meeting)
      expect(EmailServiceMock, :send_appointment_reminders, fn _, _ -> {{:ok, "sent"}, {:ok, "sent"}} end)

      assert :ok = EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{"meeting_id" => meeting.id})
    end

    test "handles send_reschedule_request" do
      meeting = insert(:meeting)
      expect(EmailServiceMock, :send_reschedule_request, fn _meeting -> {:ok, "sent"} end)

      assert :ok = EmailWorkerHandlers.execute_email_action("send_reschedule_request", %{"meeting_id" => meeting.id})
    end

    test "handles send_contact_form" do
      args = %{
        "sender_name" => "Tester",
        "sender_email" => "test@example.com",
        "subject" => "Test",
        "message" => "Hello"
      }
      expect(EmailServiceMock, :send_contact_form, fn _, _, _, _ -> {:ok, "sent"} end)

      assert :ok = EmailWorkerHandlers.execute_email_action("send_contact_form", args)
    end

    test "handles send_email_verification" do
      user = insert(:user)
      expect(EmailServiceMock, :send_email_verification, fn _, _ -> {:ok, "sent"} end)

      assert :ok = EmailWorkerHandlers.execute_email_action("send_email_verification", %{"user_id" => user.id, "verification_url" => "http://test.com"})
    end
  end

  describe "handle_confirmation_emails/1" do
    test "returns :meeting_not_found if meeting doesn't exist" do
      fake_id = UUID.generate()
      assert {:error, :meeting_not_found} =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{"meeting_id" => fake_id})
    end

    test "skips if already sent" do
      meeting = insert(:meeting, organizer_email_sent: true, attendee_email_sent: true)
      assert :ok = EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{"meeting_id" => meeting.id})
    end

    test "handles partial failure" do
      meeting = insert(:meeting)
      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _, _ -> {:ok, "sent"} end)
      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _, _ -> {:error, "failed"} end)

      assert {:error, "Failed to send all emails"} =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{"meeting_id" => meeting.id})
    end
  end

  describe "handle_reminder_emails/1" do
    test "skips if meeting is cancelled" do
      meeting = insert(:meeting, status: "cancelled")
      assert {:error, :meeting_cancelled} =
               EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{"meeting_id" => meeting.id})
    end
  end

  describe "handle_contact_form/1" do
    test "discards if fields are missing" do
      assert {:discard, reason} = EmailWorkerHandlers.execute_email_action("send_contact_form", %{})
      assert reason =~ "Missing required fields"
    end
  end
end
