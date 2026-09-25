defmodule Tymeslot.Polls.ConfirmTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm

  @moduletag :integration
  @moduletag :polls

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
      guest_emails = meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.email)
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

    test "breaks a same-second registration tie deterministically",
         %{user: user, poll: poll, slot: slot} do
      # `inserted_at` is second-precision, so two strangers following the same
      # poll link routinely share one. Inserted in the order that puts the
      # tie-break at odds with physical row order: without a total ordering,
      # the preload hands back whatever the table scan produces, and the
      # primary attendee becomes a coin flip between two people who both voted
      # for the slot.
      registered_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      bob =
        insert(:poll_participant,
          poll: poll,
          name: "Bob",
          email: "bob@example.com",
          inserted_at: registered_at
        )

      ada =
        insert(:poll_participant,
          poll: poll,
          name: "Ada",
          email: "ada@example.com",
          inserted_at: registered_at
        )

      insert(:poll_vote, participant: bob, time_slot: slot, response: :yes)
      insert(:poll_vote, participant: ada, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)

      assert meeting.attendee_email == "ada@example.com"

      guest_emails = meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.email)
      assert guest_emails == ["bob@example.com"]
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
      {:ok, confirmed} = poll |> Changeset.change(status: :confirmed) |> Repo.update()

      assert {:error, :not_open} = Confirm.confirm(confirmed.id, slot.id, user.id)
    end

    test "returns :no_participants when the poll has no participants",
         %{user: user, poll: poll, slot: slot} do
      assert {:error, :no_participants} = Confirm.confirm(poll.id, slot.id, user.id)
    end
  end

  describe "confirm/3 against the host's time off" do
    # The host lives in Berlin, so every period below is wall-clock there and
    # a slot's UTC instant lands on a different day near midnight.
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: "Europe/Berlin")
      poll = insert(:poll, user: user, status: :open, timezone: "Europe/Berlin")
      participant = insert(:poll_participant, poll: poll, email: "voter@example.com")

      %{user: user, profile: profile, poll: poll, participant: participant}
    end

    # A slot of `minutes` starting at `time` on `date`, Berlin wall-clock.
    defp berlin_slot(poll, participant, date, time, minutes) do
      start_time = date |> DateTime.new!(time, "Europe/Berlin") |> DateTime.shift_zone!("Etc/UTC")
      slot_end = DateTime.add(start_time, minutes, :minute)
      slot = insert(:poll_time_slot, poll: poll, start_time: start_time, end_time: slot_end)
      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)
      slot
    end

    defp day_off!(profile, date) do
      {:ok, period} = TimeOff.create(profile.id, %{starts_on: date, ends_on: date})
      period
    end

    defp meeting_count(user_id) do
      Repo.aggregate(from(m in MeetingSchema, where: m.organizer_user_id == ^user_id), :count)
    end

    test "refuses a slot inside time off entered after the poll went out, and mints nothing",
         %{user: user, profile: profile, poll: poll, participant: participant} do
      day = Date.add(Date.utc_today(), 10)
      slot = berlin_slot(poll, participant, day, ~T[10:00:00], 60)

      # The poll and its votes exist before the host books the day off.
      day_off!(profile, day)

      assert {:error, :time_off} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting_count(user.id) == 0

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :open
      assert reloaded.confirmed_meeting_id == nil
    end

    test "refuses a slot that only runs into time off after midnight in the host's timezone",
         %{user: user, profile: profile, poll: poll, participant: participant} do
      day = Date.add(Date.utc_today(), 10)
      # 23:30 to 00:30 Berlin: on `day` in UTC throughout, yet its last half
      # hour is on the day off.
      slot = berlin_slot(poll, participant, day, ~T[23:30:00], 60)
      day_off!(profile, Date.add(day, 1))

      assert {:error, :time_off} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting_count(user.id) == 0
    end

    test "refuses a slot inside part-day time off",
         %{user: user, profile: profile, poll: poll, participant: participant} do
      day = Date.add(Date.utc_today(), 10)
      slot = berlin_slot(poll, participant, day, ~T[14:00:00], 30)

      {:ok, _period} =
        TimeOff.create(profile.id, %{starts_on: day, ends_on: day, start_time: ~T[13:00:00]})

      assert {:error, :time_off} = Confirm.confirm(poll.id, slot.id, user.id)
    end

    test "confirms a slot that ends as the time off begins",
         %{user: user, profile: profile, poll: poll, participant: participant} do
      day = Date.add(Date.utc_today(), 10)
      slot = berlin_slot(poll, participant, day, ~T[23:00:00], 60)
      day_off!(profile, Date.add(day, 1))

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert DateTime.compare(meeting.start_time, slot.start_time) == :eq

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :confirmed
    end
  end
end
