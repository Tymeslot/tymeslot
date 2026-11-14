defmodule Tymeslot.Notifications.Email.CustomGuestRecoveryTest do
  @moduledoc "Verifies custom SMTP guest failures retry without repeating successful booking copies."

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :workers

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Ecto.UUID
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ReminderEntry
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, user_smtp_enabled: true, email_service_module: EmailServiceMock)
    owner = insert(:user)

    Repo.insert!(%UserSmtpSettingsSchema{
      user_id: owner.id,
      host: "smtp.customer.example",
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt("smtp-user"),
      password_encrypted: Encryption.encrypt("smtp-password"),
      from_address: "bookings@customer.example",
      from_name: "Customer bookings",
      enabled: true,
      revision: 1,
      tested_revision: 1,
      tested_at: DateTime.utc_now()
    })

    %{owner: owner}
  end

  for rollback <- [:settings_disabled, :feature_disabled] do
    test "pending custom guest reminders survive #{rollback} before the retry", %{owner: owner} do
      meeting = insert(:meeting, organizer_user_id: owner.id)
      guests(meeting, true)
      expect_primary(:reminder)
      expect_guest_attempt(:send_guest_reminder, :rate_limited)
      assert {:error, :rate_limited} = run("send_reminder_emails", meeting)

      if unquote(rollback) == :settings_disabled do
        {:ok, settings} = EmailSending.get_settings(owner)
        {:ok, _disabled} = EmailSending.disable_settings(owner, {settings.id, settings.revision})
      else
        with_config(:tymeslot, user_smtp_enabled: false)
      end

      expect_guest_retry(:send_guest_reminder)
      assert :ok = run("send_reminder_emails", meeting)
      assert GuestQueries.list_for_reminder(meeting.id, 30, "minutes") == []
    end
  end

  for reason <- [:rate_limited, :circuit_open, :authentication_failed] do
    test "confirmation retries a guest's #{reason} after the primary copies were stamped", %{
      owner: owner
    } do
      meeting = insert(:meeting, organizer_user_id: owner.id)
      guests(meeting)
      expect_primary(:confirmation)
      expect_guest_attempt(:send_guest_confirmation, unquote(reason))

      assert_guest_failure(run("send_confirmation_emails", meeting), unquote(reason))
      reloaded = Repo.reload!(meeting)
      assert reloaded.organizer_email_sent
      assert reloaded.attendee_email_sent

      expect_guest_retry(:send_guest_confirmation)
      assert :ok = run("send_confirmation_emails", meeting)
      assert GuestQueries.list_unsent_for_meeting(meeting.id) == []
    end

    test "reminder retries a guest's #{reason} even after the primary reminder is complete", %{
      owner: owner
    } do
      meeting = insert(:meeting, organizer_user_id: owner.id)
      guests(meeting, true)
      expect_primary(:reminder)
      expect_guest_attempt(:send_guest_reminder, unquote(reason))

      assert_guest_failure(run("send_reminder_emails", meeting), unquote(reason))

      assert %{organizer: true, attendee: true} =
               ReminderEntry.status(Repo.reload!(meeting).reminders_sent, 30, "minutes")

      expect_guest_retry(:send_guest_reminder)
      assert :ok = run("send_reminder_emails", meeting)
      assert GuestQueries.list_for_reminder(meeting.id, 30, "minutes") == []
    end
  end

  test "group reminder guest contention retries without repeating the organizer dispatch", %{
    owner: owner
  } do
    meeting = insert(:group_meeting, organizer_user_id: owner.id)
    participant = insert(:participant, meeting: meeting)
    guests(meeting, true, participant)

    expect(EmailServiceMock, :send_appointment_reminder_to_organizer, fn _email, _details ->
      {:ok, :sent}
    end)

    expect_guest_attempt(:send_guest_reminder, :rate_limited)
    assert {:error, :rate_limited} = run("send_reminder_emails", meeting)
    expect_guest_retry(:send_guest_reminder)
    assert :ok = run("send_reminder_emails", meeting)
    assert GuestQueries.list_for_reminder(meeting.id, 30, "minutes") == []
  end

  for {kind, action} <- [
        {:booked, "send_seat_confirmation_emails"},
        {:moved, "send_seat_reschedule_emails"}
      ] do
    test "a #{kind} seat retries its contended guest without repeating participant or organizer copies",
         %{owner: owner} do
      meeting = insert(:group_meeting, organizer_user_id: owner.id)
      participant = insert(:participant, meeting: meeting)
      guests(meeting, false, participant)

      expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_seat_update_to_organizer, fn kind, _email, _details ->
        assert kind == unquote(kind)
        {:ok, :sent}
      end)

      args = %{
        "meeting_id" => meeting.id,
        "participant_id" => participant.id,
        "old_participant_id" => UUID.generate()
      }

      expect_guest_attempt(:send_guest_confirmation, :rate_limited)
      assert {:error, :rate_limited} = EmailHandlers.execute_email_action(unquote(action), args)

      assert {:ok, %{confirmation_sent_at: %DateTime{}, organizer_notified_at: %DateTime{}}} =
               ParticipantQueries.get(participant.id)

      expect_guest_retry(:send_guest_confirmation)
      assert :ok = EmailHandlers.execute_email_action(unquote(action), args)
      assert GuestQueries.list_unsent_for_participant(participant.id) == []
    end
  end

  defp guests(meeting, invited? \\ false, participant \\ nil) do
    emails = ["delivered@example.com", "missed@example.com"]

    {:ok, guests} =
      if participant,
        do: Guests.create_for_participant(meeting.id, participant.id, emails),
        else: Guests.create_for_meeting(meeting.id, emails)

    if invited? do
      Enum.each(guests, &GuestQueries.mark_confirmation_sent(&1, DateTime.utc_now(:second)))
    end

    guests
  end

  defp expect_primary(:confirmation) do
    expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, _details ->
      {:ok, :sent}
    end)

    expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, _details ->
      {:ok, :sent}
    end)
  end

  defp expect_primary(:reminder) do
    expect(EmailServiceMock, :send_appointment_reminder_to_organizer, fn _email, _details ->
      {:ok, :sent}
    end)

    expect(EmailServiceMock, :send_appointment_reminder_to_attendee, fn _email, _details ->
      {:ok, :sent}
    end)
  end

  defp expect_guest_attempt(fun, reason) do
    expect(EmailServiceMock, fun, 2, fn email, details ->
      assert details.email_sender.kind == :user_smtp
      if email == "missed@example.com", do: {:error, reason}, else: {:ok, :sent}
    end)
  end

  defp expect_guest_retry(fun) do
    expect(EmailServiceMock, fun, fn "missed@example.com", _details -> {:ok, :sent} end)
  end

  defp assert_guest_failure(result, reason) when reason in [:rate_limited, :circuit_open],
    do: assert(result == {:error, reason})

  defp assert_guest_failure(result, _reason),
    do: assert(match?({:error, reason} when is_binary(reason), result))

  defp run(action, meeting) do
    EmailHandlers.execute_email_action(action, %{
      "meeting_id" => meeting.id,
      "reminder_value" => 30,
      "reminder_unit" => "minutes"
    })
  end
end
