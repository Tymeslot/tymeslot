defmodule Tymeslot.Workers.EmailWorkerMeetingHandlersTest do
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
end
