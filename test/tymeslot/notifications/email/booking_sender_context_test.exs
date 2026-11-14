defmodule Tymeslot.Notifications.Email.BookingSenderContextTest do
  @moduledoc "Verifies one organizer-owned sender is carried through a booking email execution."

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :workers

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.EmailSending.Sender
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Notifications.Email.GuestEmails
  alias Tymeslot.Notifications.Email.MeetingEmails
  alias Tymeslot.Notifications.Email.SeatEmails
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  setup do
    with_config(:tymeslot,
      user_smtp_enabled: true,
      email_service_module: EmailServiceMock
    )

    :ok
  end

  test "the disabled feature leaves legacy ownerless payloads untouched" do
    with_config(:tymeslot, user_smtp_enabled: false)
    meeting = insert(:meeting)

    assert {:ok, loaded} =
             MeetingEmails.with_meeting(meeting.id, "sender test", &{:ok, &1})

    assert loaded.email_sender == nil
    assert loaded.organizer_user_id == nil
  end

  test "a missing owner discards before any recipient callback" do
    meeting = insert(:meeting)

    assert {:discard, reason} =
             MeetingEmails.with_meeting(meeting.id, "sender test", fn _meeting ->
               flunk("an ownerless booking cannot use a previous SMTP identity")
             end)

    assert MeetingEmails.expected_discard?(reason)
  end

  test "a deleted owner's booking discards before any recipient callback" do
    owner = insert(:user)
    meeting = insert(:meeting, organizer_user_id: owner.id)
    settings(owner)
    Repo.delete!(owner)

    assert {:discard, reason} =
             MeetingEmails.with_meeting(meeting.id, "sender test", fn _meeting ->
               flunk("a deleted owner cannot send from their old SMTP identity")
             end)

    assert MeetingEmails.expected_discard?(reason)
  end

  test "confirmation copies and guest locale overlays freeze the organizer's sender" do
    owner = insert(:user)
    attendee = insert(:user)
    original = settings(owner)
    settings(attendee, %{from_address: "attendee@other.example"})

    meeting =
      insert(:meeting,
        organizer_user_id: owner.id,
        attendee_email: attendee.email,
        organizer_email_sent: false,
        attendee_email_sent: false
      )

    {:ok, [_guest]} =
      Guests.create_for_meeting(meeting.id, [
        %{email: "guest@example.com", name: "Guest", locale: "de", timezone: "Europe/Berlin"}
      ])

    sender = Sender.from_settings(original)

    expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, details ->
      assert details.email_sender == sender
      revise(original)
      {:ok, :sent}
    end)

    expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn email, details ->
      assert email == attendee.email
      assert details.email_sender == sender
      {:ok, :sent}
    end)

    expect(EmailServiceMock, :send_guest_confirmation, fn "guest@example.com", details ->
      assert details.email_sender == sender
      assert details.attendee_locale == "de"
      {:ok, :sent}
    end)

    assert :ok = MeetingEmails.handle_confirmation_emails(%{"meeting_id" => meeting.id})
    assert GuestQueries.list_unsent_for_meeting(meeting.id) == []

    # A fresh execution resolves the current version rather than retaining
    # the previous job's context on the persisted meeting.
    assert {:ok, %Sender{revision: 2, from_address: "updated@customer.example"}} =
             MeetingEmails.with_meeting(meeting.id, "sender retry", &{:ok, &1.email_sender})
  end

  test "platform fallback stays selected if the owner enables SMTP between copies" do
    owner = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: owner.id,
        organizer_email_sent: false,
        attendee_email_sent: false
      )

    {:ok, [_guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])
    sender = Sender.platform(owner.id)

    expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, fn _email, details ->
      assert details.email_sender == sender
      settings(owner)
      {:ok, :sent}
    end)

    expect(EmailServiceMock, :send_appointment_confirmation_to_attendee, fn _email, details ->
      assert details.email_sender == sender
      {:ok, :sent}
    end)

    expect(EmailServiceMock, :send_guest_confirmation, fn _email, details ->
      assert details.email_sender == sender
      {:ok, :sent}
    end)

    assert :ok = MeetingEmails.handle_confirmation_emails(%{"meeting_id" => meeting.id})

    assert {:ok, %Sender{kind: :user_smtp}} =
             MeetingEmails.with_meeting(meeting.id, "sender retry", &{:ok, &1.email_sender})
  end

  test "the guest invitation entry point preserves a guest locale view's sender" do
    owner = insert(:user)
    original = settings(owner)
    meeting = insert(:meeting, organizer_user_id: owner.id)

    {:ok, [guest]} =
      Guests.create_for_meeting(meeting.id, [
        %{email: "guest@example.com", name: "Guest", locale: "de", timezone: "Europe/Berlin"}
      ])

    expect(EmailServiceMock, :send_guest_confirmation, fn "guest@example.com", details ->
      assert details.email_sender == Sender.from_settings(original)
      assert details.attendee_locale == "de"
      {:ok, :sent}
    end)

    assert :ok =
             GuestEmails.handle_guest_invitations(%{
               "meeting_id" => meeting.id,
               "guest_ids" => [guest.id]
             })
  end

  test "a group guest's participant and locale overlays preserve the execution's sender" do
    owner = insert(:user)
    original = settings(owner)
    meeting = insert(:group_meeting, organizer_user_id: owner.id)
    participant = insert(:participant, meeting: meeting, locale: "de", timezone: "Europe/Berlin")

    {:ok, [guest]} =
      Guests.create_for_participant(meeting.id, participant.id, ["guest@example.com"])

    guest = Repo.preload(guest, :participant)

    assert :ok =
             MeetingEmails.with_meeting(meeting.id, "group guest", fn loaded ->
               [{_guest, details}] =
                 GuestNotifications.with_inviter_details(
                   [guest],
                   loaded,
                   AppointmentBuilder.from_meeting(loaded)
                 )

               assert details.email_sender == Sender.from_settings(original)
               assert details.uid == participant.id
               assert details.attendee_locale == "de"
               :ok
             end)
  end

  test "a live moved seat's old guest cancellation shares the new seat's sender" do
    assert_moved_seat_sender(false)
  end

  test "a moved seat cancelled before delivery preserves the sender on old-seat cancellations" do
    assert_moved_seat_sender(true)
  end

  test "a foreign old slot fails closed before any moved-seat delivery" do
    owner = insert(:user)
    settings(owner)
    meeting = insert(:group_meeting, organizer_user_id: owner.id)
    participant = insert(:participant, meeting: meeting)
    foreign = insert(:group_meeting, organizer_user_id: insert(:user).id)

    old_participant =
      insert(:participant, meeting: foreign, cancelled_at: DateTime.utc_now(:second))

    assert {:error, :invalid_sender} =
             SeatEmails.handle_seat_reschedule_emails(
               %{
                 "meeting_id" => meeting.id,
                 "participant_id" => participant.id,
                 "old_participant_id" => old_participant.id
               },
               nil
             )
  end

  # These fixtures skip SMTP validation because this suite tests context
  # propagation. The transport's TLS/authentication lifecycle is covered in
  # EmailSendingTest; an enabled row still satisfies its database invariants.
  defp settings(owner, attrs \\ %{}) do
    %UserSmtpSettingsSchema{
      user_id: owner.id,
      host: "smtp.customer.example",
      port: 587,
      security: :starttls,
      username_encrypted: Encryption.encrypt("booking-user"),
      password_encrypted: Encryption.encrypt("booking-password"),
      from_address: "bookings@customer.example",
      from_name: "Customer bookings",
      enabled: true,
      revision: 1,
      tested_revision: 1,
      tested_at: DateTime.utc_now()
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  defp revise(original) do
    original
    |> Changeset.change(
      revision: 2,
      tested_revision: 2,
      tested_at: DateTime.utc_now(),
      from_address: "updated@customer.example"
    )
    |> Repo.update!()
  end

  defp assert_moved_seat_sender(cancelled?) do
    owner = insert(:user)
    original = settings(owner)
    sender = Sender.from_settings(original)
    now = DateTime.utc_now(:second)
    old_meeting = insert(:group_meeting, organizer_user_id: owner.id, status: :cancelled)

    old_participant =
      insert(:participant, meeting: old_meeting, cancelled_at: now, ical_sequence: 1)

    {:ok, [old_guest]} =
      Guests.create_for_participant(old_meeting.id, old_participant.id, ["old-guest@example.com"])

    {:ok, _guest} = GuestQueries.mark_confirmation_sent(old_guest, now)

    meeting =
      insert(:group_meeting,
        organizer_user_id: owner.id,
        start_time: DateTime.add(old_meeting.start_time, 1, :day),
        end_time: DateTime.add(old_meeting.end_time, 1, :day)
      )

    participant =
      insert(:participant,
        meeting: meeting,
        email: old_participant.email,
        cancelled_at: if(cancelled?, do: now)
      )

    {:ok, [_guest]} =
      Guests.create_for_participant(meeting.id, participant.id, ["new-guest@example.com"])

    if cancelled? do
      expect(EmailServiceMock, :send_cancellation_email_to_attendee, fn email, details ->
        assert email == participant.email
        assert details.email_sender == sender
        assert details.uid == old_participant.id
        assert details.start_time == old_meeting.start_time
        revise(original)
        {:ok, :sent}
      end)
    else
      expect(EmailServiceMock, :send_seat_reschedule_to_participant, fn email, details, old ->
        assert email == participant.email
        assert details.email_sender == sender
        assert details.uid == participant.id
        assert old.uid == old_participant.id
        assert old.start_time == old_meeting.start_time
        refute Map.has_key?(old, :email_sender)
        revise(original)
        {:ok, :sent}
      end)

      expect(EmailServiceMock, :send_guest_confirmation, fn "new-guest@example.com", details ->
        assert details.email_sender == sender
        assert details.uid == participant.id
        {:ok, :sent}
      end)
    end

    expect(EmailServiceMock, :send_seat_update_to_organizer, fn :moved, _email, details ->
      assert details.email_sender == sender
      {:ok, :sent}
    end)

    expect(EmailServiceMock, :send_guest_cancellation, fn "old-guest@example.com", details ->
      assert details.email_sender == sender
      assert details.uid == old_participant.id
      assert details.start_time == old_meeting.start_time
      {:ok, :sent}
    end)

    assert :ok =
             SeatEmails.handle_seat_reschedule_emails(
               %{
                 "meeting_id" => meeting.id,
                 "participant_id" => participant.id,
                 "old_participant_id" => old_participant.id
               },
               nil
             )
  end
end
