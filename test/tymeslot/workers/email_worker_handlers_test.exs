defmodule Tymeslot.Workers.EmailWorkerHandlersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  import Mox
  import Tymeslot.Factory
  alias Ecto.UUID
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Workers.EmailWorkerHandlers

  setup :verify_on_exit!

  describe "execute_email_action/2" do
    test "discards unknown actions" do
      assert {:discard, "Unknown action: unknown"} =
               EmailWorkerHandlers.execute_email_action("unknown", %{})
    end

    test "handles send_confirmation_emails" do
      meeting = insert(:meeting)

      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _meeting, _user ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _meeting, _user ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })
    end

    test "handles send_reminder_emails" do
      meeting = insert(:meeting)

      expect(EmailServiceMock, :send_appointment_reminders, fn _meeting, _user ->
        {{:ok, "sent"}, {:ok, "sent"}}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => meeting.id
               })
    end

    test "handles send_reschedule_request" do
      meeting = insert(:meeting)
      expect(EmailServiceMock, :send_reschedule_request, fn _meeting -> {:ok, "sent"} end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_reschedule_request", %{
                 "meeting_id" => meeting.id
               })
    end

    test "handles send_email_verification" do
      user = insert(:user)
      expect(EmailServiceMock, :send_email_verification, fn _user, _url -> {:ok, "sent"} end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_email_verification", %{
                 "user_id" => user.id,
                 "verification_url" => "http://test.com"
               })
    end
  end

  describe "handle_confirmation_emails/1" do
    test "returns :meeting_not_found if meeting doesn't exist" do
      fake_id = UUID.generate()

      assert {:discard, "Meeting not found"} =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => fake_id
               })
    end

    test "skips if already sent" do
      meeting = insert(:meeting, organizer_email_sent: true, attendee_email_sent: true)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })
    end

    test "marks email_sent flags in database after successful send" do
      meeting = insert(:meeting, organizer_email_sent: false, attendee_email_sent: false)

      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.organizer_email_sent == true
      assert updated.attendee_email_sent == true
    end

    test "handles partial failure" do
      meeting = insert(:meeting)

      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:error, "failed"}
      end)

      assert {:error, "Failed to send all emails"} =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })

      # Organizer flag should be set since that send succeeded
      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.organizer_email_sent == true
      assert updated.attendee_email_sent == false
    end

    test "retry after a partial send does not re-send the organiser" do
      # First attempt: organiser send succeeds, attendee send fails.
      # The handler returns {:error, _} and Oban would re-enqueue, with
      # the DB remembering which side already went out.
      meeting = insert(:meeting, organizer_email_sent: false, attendee_email_sent: false)

      expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:error, "transient"}
      end)

      assert {:error, "Failed to send all emails"} =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })

      {:ok, after_first} = MeetingQueries.get_meeting(meeting.id)
      assert after_first.organizer_email_sent == true
      assert after_first.attendee_email_sent == false

      # Retry: only the attendee callback is expected. `verify_on_exit!`
      # enforces that :send_appointment_confirmation_to_organizer is NOT
      # called a second time — that is the retry-safety invariant.
      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_confirmation_emails", %{
                 "meeting_id" => meeting.id
               })

      {:ok, after_retry} = MeetingQueries.get_meeting(meeting.id)
      assert after_retry.organizer_email_sent == true
      assert after_retry.attendee_email_sent == true
    end
  end

  describe "handle_reminder_emails/1" do
    test "skips if meeting is cancelled" do
      meeting = insert(:meeting, status: "cancelled")

      assert {:discard, "Meeting cancelled"} =
               EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => meeting.id
               })
    end

    test "skips if a reschedule has been requested" do
      meeting = insert(:meeting, status: "reschedule_requested")

      assert {:discard, "Meeting reschedule_requested"} =
               EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => meeting.id
               })
    end

    test "skips reminder if already sent for the interval" do
      meeting =
        insert(:meeting,
          reminders_sent: [%{"value" => 30, "unit" => "minutes"}]
        )

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => meeting.id,
                 "reminder_value" => 30,
                 "reminder_unit" => "minutes"
               })

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.reminders_sent == meeting.reminders_sent
    end

    test "tracks reminder as sent after delivery" do
      meeting = insert(:meeting)

      expect(EmailServiceMock, :send_appointment_reminders, fn _meeting, _user ->
        {{:ok, "sent"}, {:ok, "sent"}}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => meeting.id,
                 "reminder_value" => 1,
                 "reminder_unit" => "hours"
               })

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert %{"value" => 1, "unit" => "hours"} in updated.reminders_sent
      assert updated.reminder_email_sent == true
    end

    test "marks reminder sent and succeeds when organizer sent but attendee fails" do
      meeting = insert(:meeting)

      expect(EmailServiceMock, :send_appointment_reminders, fn _details, _time ->
        {{:ok, "sent"}, {:error, "inactive recipient"}}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => meeting.id,
                 "reminder_value" => 30,
                 "reminder_unit" => "minutes"
               })

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert %{"value" => 30, "unit" => "minutes"} in updated.reminders_sent
      assert updated.reminder_email_sent == true
    end

    test "marks reminder sent and succeeds when attendee sent but organizer fails" do
      meeting = insert(:meeting)

      expect(EmailServiceMock, :send_appointment_reminders, fn _details, _time ->
        {{:error, "delivery failed"}, {:ok, "sent"}}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => meeting.id,
                 "reminder_value" => 30,
                 "reminder_unit" => "minutes"
               })

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert %{"value" => 30, "unit" => "minutes"} in updated.reminders_sent
      assert updated.reminder_email_sent == true
    end

    test "returns error when both organizer and attendee emails fail" do
      meeting = insert(:meeting)

      expect(EmailServiceMock, :send_appointment_reminders, fn _details, _time ->
        {{:error, "delivery failed"}, {:error, "delivery failed"}}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_reminder_emails", %{
                 "meeting_id" => meeting.id,
                 "reminder_value" => 30,
                 "reminder_unit" => "minutes"
               })

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      refute %{"value" => 30, "unit" => "minutes"} in List.wrap(updated.reminders_sent)
    end
  end

  describe "handle_email_change_verification/1" do
    test "successfully sends verification email to new address" do
      user = insert(:user)
      new_email = "new@example.com"

      expect(EmailServiceMock, :send_email_change_verification, fn _user, ^new_email, _url ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_email_change_verification", %{
                 "user_id" => user.id,
                 "new_email" => new_email,
                 "verification_url" => "https://example.com/verify/token123"
               })
    end

    test "discards job when user is not found" do
      assert {:discard, "User not found"} =
               EmailWorkerHandlers.execute_email_action("send_email_change_verification", %{
                 "user_id" => 999_999,
                 "new_email" => "new@example.com",
                 "verification_url" => "https://example.com/verify/token"
               })
    end

    test "returns error when email service fails" do
      user = insert(:user)

      expect(EmailServiceMock, :send_email_change_verification, fn _user, _new_email, _url ->
        {:error, "delivery failed"}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_email_change_verification", %{
                 "user_id" => user.id,
                 "new_email" => "new@example.com",
                 "verification_url" => "https://example.com/verify/token"
               })
    end
  end

  describe "handle_email_change_notification/1" do
    test "successfully sends security notification to old address" do
      user = insert(:user)
      new_email = "new@example.com"

      expect(EmailServiceMock, :send_email_change_notification, fn _user, ^new_email ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_email_change_notification", %{
                 "user_id" => user.id,
                 "new_email" => new_email
               })
    end

    test "discards job when user is not found" do
      assert {:discard, "User not found"} =
               EmailWorkerHandlers.execute_email_action("send_email_change_notification", %{
                 "user_id" => 999_999,
                 "new_email" => "new@example.com"
               })
    end

    test "returns error when email service fails" do
      user = insert(:user)

      expect(EmailServiceMock, :send_email_change_notification, fn _user, _new_email ->
        {:error, "delivery failed"}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_email_change_notification", %{
                 "user_id" => user.id,
                 "new_email" => "new@example.com"
               })
    end
  end

  describe "handle_integration_paused_notification/1" do
    test "happy path: returns :ok when user and calendar integration exist and email sends" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      expect(EmailServiceMock, :send_integration_paused_notification, fn _user,
                                                                         _integration,
                                                                         :calendar,
                                                                         14 ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_paused_notification",
                 %{
                   "user_id" => user.id,
                   "integration_id" => integration.id,
                   "integration_type" => "calendar",
                   "cutoff_days" => 14
                 }
               )
    end

    test "happy path: returns :ok when user and video integration exist and email sends" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      expect(EmailServiceMock, :send_integration_paused_notification, fn _user,
                                                                         _integration,
                                                                         :video,
                                                                         14 ->
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_paused_notification",
                 %{
                   "user_id" => user.id,
                   "integration_id" => integration.id,
                   "integration_type" => "video",
                   "cutoff_days" => 14
                 }
               )
    end

    test "discards when user is not found" do
      integration = insert(:calendar_integration)

      assert {:discard, "User or integration not found"} =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_paused_notification",
                 %{
                   "user_id" => 999_999,
                   "integration_id" => integration.id,
                   "integration_type" => "calendar",
                   "cutoff_days" => 14
                 }
               )
    end

    test "discards when integration is not found" do
      user = insert(:user)

      assert {:discard, "User or integration not found"} =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_paused_notification",
                 %{
                   "user_id" => user.id,
                   "integration_id" => 999_999,
                   "integration_type" => "calendar",
                   "cutoff_days" => 14
                 }
               )
    end

    test "returns error when email service fails" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      expect(EmailServiceMock, :send_integration_paused_notification, fn _user,
                                                                         _integration,
                                                                         _type,
                                                                         _cutoff_days ->
        {:error, "SMTP timeout"}
      end)

      assert {:error, "Failed to send notification"} =
               EmailWorkerHandlers.execute_email_action(
                 "send_integration_paused_notification",
                 %{
                   "user_id" => user.id,
                   "integration_id" => integration.id,
                   "integration_type" => "calendar",
                   "cutoff_days" => 14
                 }
               )
    end
  end

  describe "handle_admin_alert/1" do
    test "happy path: returns :ok and calls email service with correctly mapped args" do
      expect(EmailServiceMock, :send_admin_alert, fn recipient,
                                                     category,
                                                     severity,
                                                     message,
                                                     metadata ->
        assert recipient == "admin@example.com"
        assert category == "Webhook"
        assert severity == :warning
        assert message == "Unhandled webhook event received"
        assert metadata == %{"event_id" => "evt_001"}
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_admin_alert", %{
                 "recipient" => "admin@example.com",
                 "category" => "Webhook",
                 "severity" => "warning",
                 "message" => "Unhandled webhook event received",
                 "metadata" => %{"event_id" => "evt_001"}
               })
    end

    test "error propagation: returns {:error, reason} when email service fails" do
      expect(EmailServiceMock, :send_admin_alert, fn _recipient,
                                                     _category,
                                                     _severity,
                                                     _message,
                                                     _metadata ->
        {:error, "SMTP timeout"}
      end)

      assert {:error, "Failed to deliver admin alert"} =
               EmailWorkerHandlers.execute_email_action("send_admin_alert", %{
                 "recipient" => "admin@example.com",
                 "category" => "Webhook",
                 "severity" => "warning",
                 "message" => "Something went wrong",
                 "metadata" => %{}
               })
    end

    test "severity fallback: unknown severity string maps to :warning" do
      expect(EmailServiceMock, :send_admin_alert, fn _recipient,
                                                     _category,
                                                     severity,
                                                     _message,
                                                     _metadata ->
        assert severity == :warning
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_admin_alert", %{
                 "recipient" => "admin@example.com",
                 "category" => "General",
                 "severity" => "nonsense",
                 "message" => "Something happened",
                 "metadata" => %{}
               })
    end

    test "known severity 'info' maps to :info atom" do
      expect(EmailServiceMock, :send_admin_alert, fn _recipient,
                                                     _category,
                                                     severity,
                                                     _message,
                                                     _metadata ->
        assert severity == :info
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_admin_alert", %{
                 "recipient" => "admin@example.com",
                 "category" => "General",
                 "severity" => "info",
                 "message" => "Informational notice",
                 "metadata" => %{}
               })
    end

    test "known severity 'error' maps to :error atom" do
      expect(EmailServiceMock, :send_admin_alert, fn _recipient,
                                                     _category,
                                                     severity,
                                                     _message,
                                                     _metadata ->
        assert severity == :error
        {:ok, "sent"}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_admin_alert", %{
                 "recipient" => "admin@example.com",
                 "category" => "Payments",
                 "severity" => "error",
                 "message" => "Payment processing failed",
                 "metadata" => %{"charge_id" => "ch_001"}
               })
    end
  end

  describe "handle_email_change_confirmations/1" do
    test "successfully sends confirmations to both old and new addresses" do
      user = insert(:user)

      expect(EmailServiceMock, :send_email_change_confirmations, fn _user,
                                                                    "old@example.com",
                                                                    "new@example.com" ->
        {{:ok, "sent"}, {:ok, "sent"}}
      end)

      assert :ok =
               EmailWorkerHandlers.execute_email_action("send_email_change_confirmations", %{
                 "user_id" => user.id,
                 "old_email" => "old@example.com",
                 "new_email" => "new@example.com"
               })
    end

    test "discards job when user is not found" do
      assert {:discard, "User not found"} =
               EmailWorkerHandlers.execute_email_action("send_email_change_confirmations", %{
                 "user_id" => 999_999,
                 "old_email" => "old@example.com",
                 "new_email" => "new@example.com"
               })
    end

    test "returns error when second delivery fails" do
      user = insert(:user)

      expect(EmailServiceMock, :send_email_change_confirmations, fn _user, _old, _new ->
        {{:ok, "sent"}, {:error, "delivery failed"}}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_email_change_confirmations", %{
                 "user_id" => user.id,
                 "old_email" => "old@example.com",
                 "new_email" => "new@example.com"
               })
    end

    test "returns error when first delivery fails" do
      user = insert(:user)

      expect(EmailServiceMock, :send_email_change_confirmations, fn _user, _old, _new ->
        {{:error, "delivery failed"}, {:ok, "sent"}}
      end)

      assert {:error, _reason} =
               EmailWorkerHandlers.execute_email_action("send_email_change_confirmations", %{
                 "user_id" => user.id,
                 "old_email" => "old@example.com",
                 "new_email" => "new@example.com"
               })
    end
  end
end
