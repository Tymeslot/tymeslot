defmodule Tymeslot.Polls.ConfirmTest do
  use Tymeslot.DataCase
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Meetings
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm

  @moduletag :integration

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)

    poll =
      insert(:poll, user: user, status: :open, timezone: "Europe/Berlin", meeting_type_id: nil)

    slot_start = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
    slot_end = DateTime.add(slot_start, 1, :hour)

    slot =
      insert(:poll_time_slot, poll: poll, start_time: slot_start, end_time: slot_end)

    %{user: user, poll: poll, slot: slot}
  end

  describe "confirm/3" do
    test "picks the first available voter (not the first registrant) and mints a meeting",
         %{user: user, poll: poll, slot: slot} do
      Polls.subscribe(poll.id)

      # Alice registered first but voted :no; Bob registered later and voted :yes.
      t0 = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      alice =
        insert(:poll_participant,
          poll: poll,
          name: "Alice",
          email: "alice@example.com",
          timezone: "America/New_York",
          inserted_at: t0
        )

      bob =
        insert(:poll_participant,
          poll: poll,
          name: "Bob",
          email: "bob@example.com",
          timezone: "Europe/London",
          inserted_at: DateTime.add(t0, 60, :second)
        )

      insert(:poll_vote, participant: alice, time_slot: slot, response: :no)
      insert(:poll_vote, participant: bob, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)

      # Bob is the primary attendee: the first participant available for the slot.
      assert meeting.attendee_name == "Bob"
      assert meeting.attendee_email == "bob@example.com"
      assert meeting.attendee_timezone == "Europe/London"
      assert meeting.title == poll.title
      assert DateTime.compare(meeting.start_time, slot.start_time) == :eq
      assert DateTime.compare(meeting.end_time, slot.end_time) == :eq
      assert meeting.organizer_user_id == user.id

      # Alice becomes a guest on the minted meeting.
      guest_emails = meeting.id |> Meetings.list_meeting_guests() |> Enum.map(& &1.email)
      assert "alice@example.com" in guest_emails
      refute "bob@example.com" in guest_emails

      # The poll is now confirmed and points at the meeting.
      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :confirmed
      assert reloaded.confirmed_meeting_id == meeting.id
      assert reloaded.confirmed_at

      assert_receive {:poll_updated, broadcast_id}
      assert broadcast_id == poll.id
    end

    test "falls back to the timezone of the poll when the primary has none",
         %{user: user, poll: poll, slot: slot} do
      participant =
        insert(:poll_participant, poll: poll, email: "solo@example.com", timezone: nil)

      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.attendee_timezone == poll.timezone
    end

    test "returns :slot_taken when the organiser already has a meeting at that time",
         %{user: user, poll: poll, slot: slot} do
      insert(:poll_participant, poll: poll, email: "voter@example.com")

      insert(:meeting,
        organizer_user_id: user.id,
        status: "confirmed",
        start_time: slot.start_time,
        end_time: slot.end_time
      )

      assert {:error, :slot_taken} = Confirm.confirm(poll.id, slot.id, user.id)

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :open
      assert reloaded.confirmed_meeting_id == nil
    end

    test "does not mislabel a non-conflict booking failure as :slot_taken",
         %{user: user, poll: poll, slot: slot} do
      # Primary attendee is valid and available for the slot.
      primary = insert(:poll_participant, poll: poll, name: "Valid", email: "valid@example.com")
      insert(:poll_vote, participant: primary, time_slot: slot, response: :yes)

      # A second participant carries a malformed email (inserted straight via the
      # factory, bypassing registration validation). It becomes a guest, so the
      # guest insert fails inside the booking transaction and the ad-hoc path
      # surfaces a generic, non-conflict failure.
      insert(:poll_participant, poll: poll, email: "not-an-email")

      assert {:error, reason} = Confirm.confirm(poll.id, slot.id, user.id)
      refute reason == :slot_taken

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :open
      assert reloaded.confirmed_meeting_id == nil
    end

    test "returns :slot_in_past when the slot has already started",
         %{user: user, poll: poll} do
      insert(:poll_participant, poll: poll)

      past_start = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

      past_slot =
        insert(:poll_time_slot,
          poll: poll,
          start_time: past_start,
          end_time: DateTime.add(past_start, 1, :hour)
        )

      assert {:error, :slot_in_past} = Confirm.confirm(poll.id, past_slot.id, user.id)
    end

    test "returns :invalid_slot when the slot does not belong to the poll",
         %{user: user, poll: poll} do
      insert(:poll_participant, poll: poll)
      other_slot = insert(:poll_time_slot)

      assert {:error, :invalid_slot} = Confirm.confirm(poll.id, other_slot.id, user.id)
    end

    test "returns :not_found for a different owner", %{poll: poll, slot: slot} do
      other_user = insert(:user)
      assert {:error, :not_found} = Confirm.confirm(poll.id, slot.id, other_user.id)
    end

    test "returns :not_open for an already-confirmed poll",
         %{user: user, poll: poll, slot: slot} do
      insert(:poll_participant, poll: poll)
      {:ok, confirmed} = poll |> Ecto.Changeset.change(status: :confirmed) |> Repo.update()

      assert {:error, :not_open} = Confirm.confirm(confirmed.id, slot.id, user.id)
    end

    test "returns :no_participants when the poll has no participants",
         %{user: user, poll: poll, slot: slot} do
      assert {:error, :no_participants} = Confirm.confirm(poll.id, slot.id, user.id)
    end
  end
end
