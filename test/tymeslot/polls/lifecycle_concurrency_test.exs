defmodule Tymeslot.Polls.LifecycleConcurrencyTest do
  @moduledoc """
  Races between a poll's confirmation and the host's other lifecycle writes
  (cancel, a details edit), on real connections, staged by
  `Tymeslot.Test.RaceConductor` (see its moduledoc for why the module is
  synchronous and why `on_exit` deletes what it committed).

  The confirmation parks right after its locking read of the poll; the
  cancel or edit parks right after its first read of the poll, whatever kind
  of read that is. With the cancel and the edit reading under the same lock
  as the confirmation, one contender parks at a time and the other waits,
  then finds the poll no longer open. Reading without it, the cancel or edit
  parks having seen the poll open while the confirmation holds the lock, and
  both write.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :polls
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  setup do
    {user, poll, slot, participant} =
      unboxed(fn ->
        user = insert(:user)
        insert(:profile, user: user, username: "host#{System.unique_integer([:positive])}")

        poll =
          insert(:poll, user: user, status: :open, timezone: "Etc/UTC", meeting_type_id: nil)

        slot_start = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

        slot =
          insert(:poll_time_slot,
            poll: poll,
            start_time: slot_start,
            end_time: DateTime.add(slot_start, 1, :hour)
          )

        participant = insert(:poll_participant, poll: poll)
        insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)

        {user, poll, slot, participant}
      end)

    on_exit(fn ->
      unboxed(fn ->
        meeting_ids =
          Repo.all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id, select: m.id))

        participant_ids =
          Repo.all(from(p in PollParticipantSchema, where: p.poll_id == ^poll.id, select: p.id))

        Repo.delete_all(
          from(j in Oban.Job,
            where:
              fragment("?->>'meeting_id'", j.args) in ^meeting_ids or
                fragment("?->>'poll_id'", j.args) == ^poll.id or
                fragment("?->>'participant_id'", j.args) in ^participant_ids
          )
        )

        Repo.delete_all(from(p in PollSchema, where: p.user_id == ^user.id))
        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user, poll: poll, slot: slot, participant: participant}
  end

  test "of a cancel and a confirmation racing, exactly one takes effect", ctx do
    results =
      race([
        fn hold -> confirm(ctx, hold) end,
        fn hold -> locked(hold, fn -> Polls.cancel_poll(ctx.poll.id, ctx.user.id) end) end
      ])

    assert_one_winner(results, ctx)
  end

  # An edit that commits first is a real edit of an open poll, and the
  # confirmation that follows mints the meeting under the new title. What the
  # lock rules out is the edit landing on the poll after it was confirmed.
  test "a details edit racing a confirmation never lands on the confirmed poll", ctx do
    [confirmed, edited] =
      race([
        fn hold -> confirm(ctx, hold) end,
        fn hold ->
          locked(hold, fn ->
            Polls.update_details(ctx.poll.id, ctx.user.id, %{title: "Renamed"})
          end)
        end
      ])

    assert {:ok, %MeetingSchema{} = meeting} = confirmed
    poll = committed_poll(ctx.poll)
    assert poll.status == :confirmed

    case edited do
      {:ok, %PollSchema{}} -> assert meeting.title == "Renamed"
      {:error, :not_open} -> assert poll.title == ctx.poll.title
    end
  end

  # The edit parks at its first write to the job table. Scheduling inside its
  # transaction, it still holds the poll's row there, so a confirmation
  # started now waits for the edit to commit and then deletes the jobs the
  # edit wrote with the rest. Scheduling after its commit, it holds nothing,
  # the confirmation runs to the end, and the edit's nudge lands on a poll
  # that is already confirmed.
  test "an edit's deadline jobs never outlive a confirmation racing it", ctx do
    test_pid = self()
    moved = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

    edit =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(RaceConductor.park_here(test_pid), &job_write?/1)
          Polls.update_details(ctx.poll.id, ctx.user.id, %{"deadline_at" => moved})
        end)
      end)

    assert_receive {:parked, edit_pid}, 5_000

    confirm =
      Task.async(fn ->
        unboxed(fn -> Confirm.confirm(ctx.poll.id, ctx.slot.id, ctx.user.id) end)
      end)

    progress = RaceConductor.await_finished_or_blocked(confirm)
    send(edit_pid, :release)

    confirmed =
      case progress do
        {:finished, result} -> result
        :blocked -> Task.await(confirm, 30_000)
      end

    assert {:ok, %PollSchema{}} = Task.await(edit, 30_000)
    assert {:ok, %MeetingSchema{}} = confirmed
    assert committed_poll(ctx.poll).status == :confirmed
    assert pending_deadline_jobs(ctx.poll) == []
  end

  # Remove-first, the confirmation finds nobody to meet. Confirm-first, the
  # removal finds the poll closed. Reading without the lock, the removal
  # parks having seen the poll open, the confirmation mints a meeting with
  # the participant on it, and the removal then deletes them from a
  # confirmed poll.
  test "of a participant removal and a confirmation racing, exactly one takes effect", ctx do
    [confirmed, removed] =
      race([
        fn hold -> confirm(ctx, hold) end,
        fn hold ->
          locked(hold, fn ->
            Polls.remove_participant(ctx.poll.id, ctx.user.id, ctx.participant.id)
          end)
        end
      ])

    case {confirmed, removed} do
      {{:ok, %MeetingSchema{}}, {:error, :not_open}} ->
        assert committed_participant(ctx.participant)

      {{:error, :no_participants}, :ok} ->
        assert committed_poll(ctx.poll).status == :open
        refute committed_participant(ctx.participant)

      both ->
        flunk("expected exactly one write to take effect, got #{inspect(both)}")
    end
  end

  # The confirmation parks holding the poll's lock. The invitation starts
  # now and, reading under that lock, waits for it; reading without it, the
  # invitation parks having seen the poll open and would then write to a
  # poll the confirmation closes. Released, the confirmation commits and the
  # invitation finds the poll closed: nobody is invited and nothing is
  # scheduled.
  test "an invitation racing a confirmation never lands on the confirmed poll", ctx do
    test_pid = self()
    email = "late-invitee@example.com"

    # With a deadline ahead, an invitation that got through would schedule
    # deadline reminders for the confirmed poll.
    unboxed(fn ->
      deadline = DateTime.utc_now() |> DateTime.add(5, :day) |> DateTime.truncate(:second)
      ctx.poll |> Changeset.change(deadline_at: deadline) |> Repo.update!()
    end)

    confirm =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(RaceConductor.park_here(test_pid), RaceConductor.lock_of("polls"))
          Confirm.confirm(ctx.poll.id, ctx.slot.id, ctx.user.id)
        end)
      end)

    assert_receive {:parked, confirm_pid}, 5_000

    invite =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(RaceConductor.park_here(test_pid), &first_poll_read?/1)
          Polls.invite_participants(ctx.poll.id, ctx.user.id, [%{email: email, name: nil}])
        end)
      end)

    assert :blocked = RaceConductor.await_finished_or_blocked(invite, 5_000)
    send(confirm_pid, :release)

    assert {:ok, %MeetingSchema{}} = Task.await(confirm, 30_000)

    # Its lock read now returns, and it parks there for the test to release.
    assert_receive {:parked, invite_pid}, 5_000
    send(invite_pid, :release)

    assert {:error, :not_open} = Task.await(invite, 30_000)
    assert committed_poll(ctx.poll).status == :confirmed
    refute invitee_on_poll?(ctx.poll, email)
    assert invitation_jobs(ctx.poll) == []
    assert pending_deadline_jobs(ctx.poll) == []
  end

  # The loser waits on the winner's row lock, then finds the poll no longer
  # open; whichever got there first, the committed poll is the winner's.
  defp assert_one_winner([confirmed, cancelled], ctx) do
    poll = committed_poll(ctx.poll)

    case {confirmed, cancelled} do
      {{:ok, %MeetingSchema{}}, {:error, :not_open}} ->
        assert poll.status == :confirmed

      {{:error, :not_open}, {:ok, %PollSchema{}}} ->
        assert poll.status == :cancelled
        assert committed_meetings(ctx.user) == 0

      both ->
        flunk("expected exactly one write to take effect, got #{inspect(both)}")
    end
  end

  defp confirm(ctx, hold) do
    RaceConductor.arm(hold, RaceConductor.lock_of("polls"))
    Confirm.confirm(ctx.poll.id, ctx.slot.id, ctx.user.id)
  end

  # Parks on the contender's first read of the poll, locking or not, so that
  # without the lock it is sure to have seen the poll open before the
  # confirmation commits.
  defp locked(hold, fun) do
    RaceConductor.arm(hold, &first_poll_read?/1)
    fun.()
  end

  defp first_poll_read?(metadata),
    do: metadata[:source] == "polls" and metadata[:query] =~ ~r/^SELECT/

  defp job_write?(metadata), do: metadata[:source] == "oban_jobs"

  defp pending_deadline_jobs(poll) do
    unboxed(fn ->
      Repo.all(
        from(j in Oban.Job,
          where: fragment("?->>'poll_id'", j.args) == ^poll.id,
          where:
            fragment("?->>'action'", j.args) in [
              "send_poll_deadline_reminders",
              "send_poll_host_nudge"
            ],
          where: j.state in ["available", "scheduled", "retryable"]
        )
      )
    end)
  end

  defp invitee_on_poll?(poll, email) do
    unboxed(fn ->
      Repo.exists?(
        from(p in PollParticipantSchema, where: p.poll_id == ^poll.id and p.email == ^email)
      )
    end)
  end

  defp invitation_jobs(poll) do
    unboxed(fn ->
      participant_ids =
        Repo.all(from(p in PollParticipantSchema, where: p.poll_id == ^poll.id, select: p.id))

      Repo.all(
        from(j in Oban.Job,
          where: fragment("?->>'action'", j.args) == "send_poll_invitation",
          where: fragment("?->>'participant_id'", j.args) in ^participant_ids
        )
      )
    end)
  end

  defp committed_participant(participant),
    do: unboxed(fn -> Repo.get(PollParticipantSchema, participant.id) end)

  defp committed_poll(poll), do: unboxed(fn -> Repo.get!(PollSchema, poll.id) end)

  defp committed_meetings(user) do
    unboxed(fn ->
      Repo.aggregate(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id), :count)
    end)
  end
end
