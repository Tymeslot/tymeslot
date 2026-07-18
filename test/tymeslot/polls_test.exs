defmodule Tymeslot.PollsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit

  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollSchema

  import Tymeslot.Factory

  setup do
    user = insert(:user)
    future = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
    {:ok, user: user, future: future}
  end

  defp slot(start_time), do: %{start_time: start_time}
  defp slot(start_time, end_time), do: %{start_time: start_time, end_time: end_time}

  describe "create_poll/2 without a meeting type" do
    test "inserts the poll and its slots with 0-based positions, preloaded", %{
      user: user,
      future: future
    } do
      attrs = %{
        title: "Team sync",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        slots: [
          slot(future),
          slot(DateTime.add(future, 1, :hour)),
          slot(DateTime.add(future, 2, :hour))
        ]
      }

      assert {:ok, poll} = Polls.create_poll(user.id, attrs)
      assert %PollSchema{title: "Team sync", duration_minutes: 30, status: :open} = poll
      assert poll.user_id == user.id
      assert [%{position: 0}, %{position: 1}, %{position: 2}] = poll.time_slots
      assert poll.participants == []
    end

    test "defaults each slot's end_time from the duration when omitted", %{
      user: user,
      future: future
    } do
      attrs = %{
        title: "Team sync",
        duration_minutes: 45,
        timezone: "Etc/UTC",
        slots: [slot(future)]
      }

      assert {:ok, %{time_slots: [slot]}} = Polls.create_poll(user.id, attrs)
      assert slot.start_time == future
      assert slot.end_time == DateTime.add(future, 45 * 60, :second)
    end

    test "keeps an explicit per-slot end_time", %{user: user, future: future} do
      explicit_end = DateTime.add(future, 90 * 60, :second)

      attrs = %{
        title: "Team sync",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        slots: [slot(future, explicit_end)]
      }

      assert {:ok, %{time_slots: [%{end_time: ^explicit_end}]}} =
               Polls.create_poll(user.id, attrs)
    end
  end

  describe "create_poll/2 with a meeting type" do
    test "snapshots title from the type name and duration when not provided", %{
      user: user,
      future: future
    } do
      meeting_type =
        insert(:meeting_type, user: user, name: "Discovery call", duration_minutes: 25)

      attrs = %{
        timezone: "Etc/UTC",
        meeting_type_id: meeting_type.id,
        slots: [slot(future)]
      }

      assert {:ok, poll} = Polls.create_poll(user.id, attrs)
      assert poll.title == "Discovery call"
      assert poll.duration_minutes == 25
      assert poll.meeting_type_id == meeting_type.id
    end

    test "explicit attrs override the snapshot", %{user: user, future: future} do
      meeting_type =
        insert(:meeting_type, user: user, name: "Discovery call", duration_minutes: 25)

      attrs = %{
        title: "Custom title",
        duration_minutes: 60,
        timezone: "Etc/UTC",
        meeting_type_id: meeting_type.id,
        slots: [slot(future)]
      }

      assert {:ok, poll} = Polls.create_poll(user.id, attrs)
      assert poll.title == "Custom title"
      assert poll.duration_minutes == 60
    end

    test "returns an error when the meeting type is not found for the user", %{
      user: user,
      future: future
    } do
      other_type = insert(:meeting_type)

      attrs = %{
        timezone: "Etc/UTC",
        meeting_type_id: other_type.id,
        slots: [slot(future)]
      }

      assert {:error, :meeting_type_not_found} = Polls.create_poll(user.id, attrs)
    end

    test "returns an error for a payment-required type", %{user: user, future: future} do
      meeting_type = insert(:meeting_type, user: user, payment_required: true)

      attrs = %{
        title: "Paid",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        meeting_type_id: meeting_type.id,
        slots: [slot(future)]
      }

      assert {:error, :payment_required_type} = Polls.create_poll(user.id, attrs)
    end
  end

  describe "create_poll/2 slot validation" do
    test "rejects an empty slot list", %{user: user} do
      attrs = %{title: "T", duration_minutes: 30, timezone: "Etc/UTC", slots: []}
      assert {:error, :no_slots} = Polls.create_poll(user.id, attrs)
    end

    test "rejects more than the maximum number of slots", %{user: user, future: future} do
      slots = for i <- 1..(PollSchema.max_slots() + 1), do: slot(DateTime.add(future, i, :hour))
      attrs = %{title: "T", duration_minutes: 30, timezone: "Etc/UTC", slots: slots}
      assert {:error, :too_many_slots} = Polls.create_poll(user.id, attrs)
    end

    test "rejects a slot whose start_time is in the past", %{user: user, future: future} do
      past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      attrs = %{
        title: "T",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        slots: [slot(future), slot(past)]
      }

      assert {:error, :slot_in_past} = Polls.create_poll(user.id, attrs)
    end

    test "rolls back when two slots share the same start_time", %{user: user, future: future} do
      attrs = %{
        title: "T",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        slots: [slot(future), slot(future)]
      }

      assert {:error, %Ecto.Changeset{}} = Polls.create_poll(user.id, attrs)
      assert Polls.list_polls(user.id) == []
    end
  end

  describe "get_poll_for_voting/1" do
    test "returns the poll for any status by token", %{user: user, future: future} do
      {:ok, poll} = create_basic_poll(user, future)
      assert {:ok, found} = Polls.get_poll_for_voting(poll.token)
      assert found.id == poll.id
    end

    test "returns not_found for an unknown token" do
      assert {:error, :not_found} = Polls.get_poll_for_voting("nope")
    end
  end

  describe "get_poll_for_host/2" do
    test "returns the poll scoped to the owner", %{user: user, future: future} do
      {:ok, poll} = create_basic_poll(user, future)
      assert {:ok, found} = Polls.get_poll_for_host(poll.id, user.id)
      assert found.id == poll.id
    end

    test "returns not_found for another user", %{user: user, future: future} do
      {:ok, poll} = create_basic_poll(user, future)
      other = insert(:user)
      assert {:error, :not_found} = Polls.get_poll_for_host(poll.id, other.id)
    end
  end

  describe "list_polls/1" do
    test "returns the user's polls newest first", %{user: user} do
      now = DateTime.utc_now(:second)
      older = insert(:poll, user: user, inserted_at: DateTime.add(now, -1, :hour))
      newer = insert(:poll, user: user, inserted_at: now)

      ids = user.id |> Polls.list_polls() |> Enum.map(& &1.id)
      assert ids == [newer.id, older.id]
    end
  end

  describe "cancel_poll/2" do
    test "cancels an open poll", %{user: user, future: future} do
      {:ok, poll} = create_basic_poll(user, future)
      assert {:ok, %{status: :cancelled}} = Polls.cancel_poll(poll.id, user.id)
    end

    test "refuses to cancel a poll that is not open", %{user: user} do
      confirmed = insert(:poll, user: user, status: :confirmed)
      assert {:error, :not_open} = Polls.cancel_poll(confirmed.id, user.id)
    end

    test "refuses to cancel a poll owned by another user", %{user: user, future: future} do
      {:ok, poll} = create_basic_poll(user, future)
      other = insert(:user)
      assert {:error, :not_found} = Polls.cancel_poll(poll.id, other.id)
    end

    test "broadcasts an update to subscribers", %{user: user, future: future} do
      {:ok, poll} = create_basic_poll(user, future)
      :ok = Polls.subscribe(poll.id)

      assert {:ok, _cancelled} = Polls.cancel_poll(poll.id, user.id)
      assert_receive {:poll_updated, poll_id}
      assert poll_id == poll.id
    end
  end

  describe "tallies/1" do
    test "counts yes/if_need_be/no per slot, including zero-vote slots", %{
      user: user,
      future: future
    } do
      poll = insert(:poll, user: user)
      slot1 = insert(:poll_time_slot, poll: poll, position: 0, start_time: future)

      slot2 =
        insert(:poll_time_slot,
          poll: poll,
          position: 1,
          start_time: DateTime.add(future, 1, :hour)
        )

      slot3 =
        insert(:poll_time_slot,
          poll: poll,
          position: 2,
          start_time: DateTime.add(future, 2, :hour)
        )

      participant_a = insert(:poll_participant, poll: poll)
      participant_b = insert(:poll_participant, poll: poll)

      insert(:poll_vote, participant: participant_a, time_slot: slot1, response: :yes)
      insert(:poll_vote, participant: participant_a, time_slot: slot2, response: :if_need_be)
      insert(:poll_vote, participant: participant_b, time_slot: slot1, response: :yes)
      insert(:poll_vote, participant: participant_b, time_slot: slot2, response: :no)

      {:ok, loaded} = Polls.get_poll_for_host(poll.id, user.id)
      tallies = Polls.tallies(loaded)

      assert tallies[slot1.id] == %{yes: 2, if_need_be: 0, no: 0}
      assert tallies[slot2.id] == %{yes: 0, if_need_be: 1, no: 1}
      assert tallies[slot3.id] == %{yes: 0, if_need_be: 0, no: 0}
    end
  end

  describe "voting_open?/1" do
    test "true for an open poll with no deadline" do
      assert Polls.voting_open?(build(:poll, status: :open, deadline_at: nil))
    end

    test "true for an open poll with a future deadline" do
      future = DateTime.add(DateTime.utc_now(), 1, :day)
      assert Polls.voting_open?(build(:poll, status: :open, deadline_at: future))
    end

    test "false for an open poll with a past deadline" do
      past = DateTime.add(DateTime.utc_now(), -1, :day)
      refute Polls.voting_open?(build(:poll, status: :open, deadline_at: past))
    end

    test "false for a confirmed poll" do
      refute Polls.voting_open?(build(:poll, status: :confirmed, deadline_at: nil))
    end

    test "false for a cancelled poll" do
      refute Polls.voting_open?(build(:poll, status: :cancelled, deadline_at: nil))
    end
  end

  defp create_basic_poll(user, start_time) do
    Polls.create_poll(user.id, %{
      title: "Team sync",
      duration_minutes: 30,
      timezone: "Etc/UTC",
      slots: [slot(start_time)]
    })
  end
end
