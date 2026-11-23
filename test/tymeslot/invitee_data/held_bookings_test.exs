defmodule Tymeslot.InviteeData.HeldBookingsTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability
  alias Tymeslot.InviteeData
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationJobs
  alias Tymeslot.Meetings.EmailVerificationToken
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker

  @email "ada@example.com"

  describe "erasing an invitee with a booking held for email confirmation" do
    test "erases the booking without naming it, releasing the hold" do
      held = insert(:awaiting_verification_meeting, attendee_email: @email)

      assert {:ok, %{meetings: 1}} = InviteeData.erase(@email)

      released = Repo.get!(MeetingSchema, held.id)
      assert %{status: :cancelled, attendee_email: nil} = released
      assert {:error, :expired} = EmailVerification.verify(released)
    end

    test "a host-scoped erasure is not blocked by it either" do
      host = insert(:user)
      held = insert(:awaiting_verification_meeting, organizer_user: host, attendee_email: @email)

      assert {:ok, %{meetings: 1}} = InviteeData.erase_for_host(host.id, @email)
      assert %{status: :cancelled} = Repo.get!(MeetingSchema, held.id)
    end

    test "is not blocked by a guest invitation on the held booking" do
      held = insert(:awaiting_verification_meeting)

      {:ok, guest} =
        GuestQueries.insert_guest(%{
          meeting_id: held.id,
          email: "guest@example.com",
          name: "A Guest"
        })

      assert {:ok, %{guests: 1}} = InviteeData.erase("guest@example.com")
      assert %{status: :awaiting_verification} = Repo.get!(MeetingSchema, held.id)
      assert %{email: "erased-" <> _rest} = Repo.get!(GuestSchema, guest.id)
    end
  end

  describe "erasing an invitee with a group seat held for email confirmation" do
    test "a held seat on a confirmed slot neither blocks the erasure nor is named" do
      slot = group_slot(:confirmed)
      insert(:participant, meeting: slot, email: "other@example.com")
      held = held_seat(slot)

      assert {:ok, %{participants: 1}} = InviteeData.erase(@email)

      assert %{status: :confirmed, cancelled_at: nil} = Repo.get!(MeetingSchema, slot.id)

      assert %{cancelled_at: %DateTime{}, email: "erased-" <> _rest} =
               Repo.get!(ParticipantSchema, held.id)
    end

    test "a held seat on a held slot is released, voiding the slot and its link" do
      slot = group_slot(:awaiting_verification)
      held = held_seat(slot)
      :ok = EmailVerificationJobs.schedule_seat_expiry(held)
      token = EmailVerificationToken.sign_seat(held)
      :ok = Availability.subscribe(slot.organizer_user_id)

      assert {:ok, %{participants: 1}} = InviteeData.erase(@email)

      assert_received {:availability_changed, organiser_id}
      assert organiser_id == slot.organizer_user_id

      assert %{status: :expired, cancelled_at: %DateTime{}} = Repo.get!(MeetingSchema, slot.id)
      assert %{cancelled_at: %DateTime{}} = Repo.get!(ParticipantSchema, held.id)
      refute_enqueued(worker: EmailVerificationExpiryWorker)

      assert {:ok, {:seat, seat, voided}} = EmailVerificationToken.verify(token)
      assert EmailVerification.seat_standing(voided, seat) == :gone
      assert {:error, :expired} = EmailVerification.verify_seat(seat)
      assert %{status: :expired} = Repo.get!(MeetingSchema, slot.id)
    end

    test "a host-scoped erasure leaves a seat held with another host alone" do
      host = insert(:user)
      slot = group_slot(:awaiting_verification)
      held = held_seat(slot)

      assert {:ok, %{participants: 0}} = InviteeData.erase_for_host(host.id, @email)

      assert %{status: :awaiting_verification} = Repo.get!(MeetingSchema, slot.id)
      assert %{cancelled_at: nil, email: @email} = Repo.get!(ParticipantSchema, held.id)
    end
  end

  defp group_slot(status) do
    start_time = DateTime.add(DateTime.utc_now(:second), 2, :day)

    organiser = insert(:user)

    insert(:group_meeting,
      organizer_user_id: organiser.id,
      organizer_email: organiser.email,
      status: status,
      capacity: 3,
      verification_deadline_at: slot_deadline(status),
      start_time: start_time,
      end_time: DateTime.add(start_time, 1, :hour)
    )
  end

  defp slot_deadline(:awaiting_verification),
    do: DateTime.add(DateTime.utc_now(:second), 30, :minute)

  defp slot_deadline(_status), do: nil

  defp held_seat(slot) do
    insert(:participant,
      meeting: slot,
      email: @email,
      verification_deadline_at: DateTime.add(DateTime.utc_now(:second), 30, :minute)
    )
  end
end
