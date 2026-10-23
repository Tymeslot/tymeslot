defmodule Tymeslot.Polls.EditingTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :unit
  @moduletag :polls

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.PollScheduler
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantSchema, PollSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup do
    user = insert(:user)
    insert(:profile, user: user, username: "host#{System.unique_integer([:positive])}")
    deadline = in_days(5)

    poll =
      insert(:poll,
        user: user,
        status: :open,
        duration_minutes: 45,
        timezone: "Etc/UTC",
        deadline_at: deadline
      )

    slot = insert(:poll_time_slot, poll: poll, start_time: in_days(7), position: 0)
    %{user: user, poll: poll, slot: slot, deadline: deadline}
  end

  describe "reminders" do
    test "a poll from before reminders were configurable is reminded a day ahead", ctx do
      assert PollSchema.reminders(ctx.poll) == [%{value: 1, unit: "days"}]
    end

    test "are scheduled before the deadline as configured", %{user: user} do
      deadline = in_days(10)

      {:ok, poll} =
        Polls.create_poll(user.id, %{
          title: "Offsite",
          duration_minutes: 30,
          timezone: "Etc/UTC",
          deadline_at: deadline,
          reminder_config: [%{"value" => 3, "unit" => "days"}, %{"value" => 1, "unit" => "days"}],
          invitees: [%{email: "ada@example.com", name: nil}],
          slots: [%{start_time: in_days(14)}]
        })

      assert reminder_times(poll.id) == [
               DateTime.add(deadline, -3, :day),
               DateTime.add(deadline, -1, :day)
             ]
    end

    test "none are scheduled when the host removed them all", %{user: user} do
      {:ok, poll} =
        Polls.create_poll(user.id, %{
          title: "Offsite",
          duration_minutes: 30,
          timezone: "Etc/UTC",
          deadline_at: in_days(10),
          reminder_config: [],
          invitees: [%{email: "ada@example.com", name: nil}],
          slots: [%{start_time: in_days(14)}]
        })

      assert reminder_times(poll.id) == []
    end

    test "are refused beyond the reminder policy", ctx do
      too_many = for days <- 1..4, do: %{"value" => days, "unit" => "days"}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"reminder_config" => too_many})

      assert %{reminder_config: [_message]} = errors_on(changeset)
    end
  end

  describe "update_details/4 with a new deadline" do
    test "replaces the pending reminders and deadline nudge for the new deadline", ctx do
      insert_invitee(ctx.poll)
      PollScheduler.schedule_reminders(ctx.poll)
      PollScheduler.schedule_deadline_nudge(ctx.poll)
      new_deadline = in_days(8)

      assert {:ok, updated} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{
                 "deadline_at" => new_deadline,
                 "reminder_config" => [%{"value" => 2, "unit" => "days"}]
               })

      assert updated.deadline_at == new_deadline
      assert reminder_times(ctx.poll.id) == [DateTime.add(new_deadline, -2, :day)]

      assert [%{scheduled_at: nudge_at}] = deadline_nudges(ctx.poll.id)
      assert DateTime.compare(nudge_at, new_deadline) == :eq
    end

    test "set again after the deadline passed reopens voting", ctx do
      Repo.update!(Changeset.change(ctx.poll, deadline_at: in_days(-1)))
      {:ok, closed} = Polls.get_poll_for_voting(ctx.poll.token)
      refute Polls.voting_open?(closed)

      assert {:ok, reopened} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"deadline_at" => in_days(3)})

      assert Polls.voting_open?(reopened)
    end

    test "cleared, leaves voting open with nothing scheduled", ctx do
      insert_invitee(ctx.poll)
      PollScheduler.schedule_reminders(ctx.poll)
      PollScheduler.schedule_deadline_nudge(ctx.poll)

      assert {:ok, updated} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"deadline_at" => nil})

      assert updated.deadline_at == nil
      assert reminder_times(ctx.poll.id) == []
      assert deadline_nudges(ctx.poll.id) == []
    end

    test "is refused in the past", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"deadline_at" => in_days(-1)})

      assert %{deadline_at: [_message]} = errors_on(changeset)
    end

    test "leaves the title alone when only the deadline changes", ctx do
      assert {:ok, updated} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"deadline_at" => in_days(9)})

      assert updated.title == ctx.poll.title
    end
  end

  describe "update_details/4 with new times" do
    test "adds them after the existing ones, as long as the poll's meetings", ctx do
      first = in_days(9)
      second = in_days(8)

      assert {:ok, _updated} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{}, [first, second])

      {:ok, poll} = Polls.get_poll_for_host(ctx.poll.id, ctx.user.id)
      assert [original, added_early, added_late] = poll.time_slots
      assert original.id == ctx.slot.id
      assert {added_early.start_time, added_late.start_time} == {second, first}
      assert added_early.position > original.position
      assert DateTime.diff(added_early.end_time, added_early.start_time, :minute) == 45

      assert [%{args: %{"slot_ids" => slot_ids}}] = jobs(ctx.poll.id, "send_poll_new_times")
      assert Enum.sort(slot_ids) == Enum.sort([added_early.id, added_late.id])
    end

    test "refuses a time in the past and saves nothing", ctx do
      assert {:error, :slot_in_past} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"title" => "Renamed"}, [
                 in_days(-1)
               ])

      {:ok, poll} = Polls.get_poll_for_host(ctx.poll.id, ctx.user.id)
      assert poll.title == ctx.poll.title
      assert length(poll.time_slots) == 1
    end

    test "refuses a time the poll already has", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{}, [ctx.slot.start_time])

      assert jobs(ctx.poll.id, "send_poll_new_times") == []
    end

    test "refuses more times than a poll can hold", ctx do
      starts = for n <- 1..PollSchema.max_slots(), do: in_days(10 + n)

      assert {:error, :too_many_slots} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{}, starts)
    end

    test "refuses a poll that is no longer open", ctx do
      Repo.update!(Changeset.change(ctx.poll, status: :cancelled))

      assert {:error, :not_open} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{}, [in_days(9)])
    end
  end

  describe "update_details/4 with a meeting type" do
    test "sets the host's own type and clears it again, leaving title and times", ctx do
      meeting_type =
        insert(:meeting_type, user: ctx.user, name: "Office hours", duration_minutes: 90)

      assert {:ok, updated} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{
                 "meeting_type_id" => meeting_type.id
               })

      assert updated.meeting_type_id == meeting_type.id
      assert updated.title == ctx.poll.title
      assert updated.duration_minutes == ctx.poll.duration_minutes

      assert {:ok, cleared} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"meeting_type_id" => nil})

      assert cleared.meeting_type_id == nil
    end

    test "an empty id, as a form sends for no type, clears it", ctx do
      meeting_type = insert(:meeting_type, user: ctx.user)
      Repo.update!(Changeset.change(ctx.poll, meeting_type_id: meeting_type.id))

      assert {:ok, cleared} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"meeting_type_id" => ""})

      assert cleared.meeting_type_id == nil
    end

    test "keeps a type switched off since, when the edit leaves it alone", ctx do
      switched_off = insert(:meeting_type, user: ctx.user, is_active: false)
      Repo.update!(Changeset.change(ctx.poll, meeting_type_id: switched_off.id))

      assert {:ok, updated} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{
                 "title" => "Renamed",
                 "meeting_type_id" => switched_off.id
               })

      assert updated.title == "Renamed"
      assert updated.meeting_type_id == switched_off.id
    end

    test "keeps a type that has started taking payment, when the edit leaves it alone", ctx do
      paid = insert(:meeting_type, user: ctx.user, payment_required: true)
      Repo.update!(Changeset.change(ctx.poll, meeting_type_id: paid.id))

      assert {:ok, updated} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{
                 "title" => "Renamed",
                 "meeting_type_id" => to_string(paid.id)
               })

      assert updated.meeting_type_id == paid.id
    end

    test "refuses another host's type, a paid one and a one-off event", ctx do
      foreign = insert(:meeting_type, user: insert(:user))
      paid = insert(:meeting_type, user: ctx.user, payment_required: true)

      assert {:error, :meeting_type_not_found} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"meeting_type_id" => foreign.id})

      assert {:error, :payment_required_type} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"meeting_type_id" => paid.id})

      one_off = insert(:meeting_type, user: ctx.user, one_off: true)

      assert {:error, :meeting_type_not_found} =
               Polls.update_details(ctx.poll.id, ctx.user.id, %{"meeting_type_id" => one_off.id})

      assert Repo.get!(PollSchema, ctx.poll.id).meeting_type_id == nil
    end
  end

  describe "remove_participant/3" do
    test "removes them with their responses", ctx do
      participant = insert(:poll_participant, poll: ctx.poll)
      insert(:poll_vote, participant: participant, time_slot: ctx.slot, response: :yes)

      assert :ok = Polls.remove_participant(ctx.poll.id, ctx.user.id, participant.id)

      assert Repo.get(PollParticipantSchema, participant.id) == nil
      {:ok, poll} = Polls.get_poll_for_voting(ctx.poll.token)
      assert Polls.tallies(poll)[ctx.slot.id].yes == 0
    end

    test "takes an id that is not a UUID as no participant of the poll", ctx do
      assert {:error, :not_found} =
               Polls.remove_participant(ctx.poll.id, ctx.user.id, "not-a-uuid")
    end

    test "nudges the host once everyone left has voted", ctx do
      insert_invitee(ctx.poll, voted_at: DateTime.utc_now(:second))
      owing = insert_invitee(ctx.poll)

      assert :ok = Polls.remove_participant(ctx.poll.id, ctx.user.id, owing.id)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_poll_host_nudge",
          "poll_id" => ctx.poll.id,
          "variant" => "all_voted"
        }
      )
    end

    test "does not nudge the host while someone left still owes a vote", ctx do
      voted = insert_invitee(ctx.poll, voted_at: DateTime.utc_now(:second))
      insert_invitee(ctx.poll)

      assert :ok = Polls.remove_participant(ctx.poll.id, ctx.user.id, voted.id)

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_host_nudge", "variant" => "all_voted"}
      )
    end

    test "does not reach a participant of another poll", ctx do
      stranger = insert(:poll_participant)

      assert {:error, :not_found} =
               Polls.remove_participant(ctx.poll.id, ctx.user.id, stranger.id)

      assert Repo.get(PollParticipantSchema, stranger.id)
    end

    test "is refused once the poll is closed", ctx do
      participant = insert(:poll_participant, poll: ctx.poll)
      Repo.update!(Changeset.change(ctx.poll, status: :cancelled))

      assert {:error, :not_open} =
               Polls.remove_participant(ctx.poll.id, ctx.user.id, participant.id)
    end
  end

  describe "delete_poll/2" do
    test "deletes a poll that is over, with its times and participants", ctx do
      participant = insert(:poll_participant, poll: ctx.poll)
      Repo.update!(Changeset.change(ctx.poll, status: :cancelled))

      assert :ok = Polls.delete_poll(ctx.poll.id, ctx.user.id)

      assert Repo.get(PollSchema, ctx.poll.id) == nil
      assert Repo.get(PollParticipantSchema, participant.id) == nil
    end

    test "keeps the meeting a confirmed poll scheduled", ctx do
      meeting = insert(:meeting, organizer_user_id: ctx.user.id)

      Repo.update!(
        Changeset.change(ctx.poll,
          status: :confirmed,
          confirmed_meeting_id: meeting.id,
          confirmed_at: DateTime.utc_now(:second)
        )
      )

      assert :ok = Polls.delete_poll(ctx.poll.id, ctx.user.id)
      assert Repo.get(MeetingSchema, meeting.id)
    end

    test "refuses an open poll, which has to be cancelled first", ctx do
      assert {:error, :still_open} = Polls.delete_poll(ctx.poll.id, ctx.user.id)
      assert Repo.get(PollSchema, ctx.poll.id)
    end

    test "does not reach another host's poll", ctx do
      Repo.update!(Changeset.change(ctx.poll, status: :cancelled))

      assert {:error, :not_found} = Polls.delete_poll(ctx.poll.id, insert(:user).id)
    end
  end

  # Someone the host invited who has not voted: who the reminders are for.
  defp insert_invitee(poll, attrs \\ []) do
    now = DateTime.utc_now(:second)

    insert(
      :poll_participant,
      Keyword.merge(
        [poll: poll, invited_at: now, confirmed_at: now, link_sent_at: now, voted_at: nil],
        attrs
      )
    )
  end

  defp in_days(days), do: DateTime.add(DateTime.utc_now(:second), days, :day)

  defp jobs(poll_id, action) do
    Enum.filter(
      all_enqueued(worker: EmailWorker, args: %{"poll_id" => poll_id}),
      &(&1.args["action"] == action)
    )
  end

  defp reminder_times(poll_id) do
    poll_id
    |> jobs("send_poll_deadline_reminders")
    |> Enum.map(&DateTime.truncate(&1.scheduled_at, :second))
    |> Enum.sort(DateTime)
  end

  defp deadline_nudges(poll_id) do
    poll_id
    |> jobs("send_poll_host_nudge")
    |> Enum.filter(&(&1.args["variant"] == "deadline_passed"))
  end
end
