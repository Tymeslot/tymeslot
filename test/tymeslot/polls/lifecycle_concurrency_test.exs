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

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  setup do
    {user, poll, slot} =
      unboxed(fn ->
        user = insert(:user)
        insert(:profile, user: user)

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

        {user, poll, slot}
      end)

    on_exit(fn ->
      unboxed(fn ->
        meeting_ids =
          Repo.all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id, select: m.id))

        Repo.delete_all(
          from(j in Oban.Job,
            where:
              fragment("?->>'meeting_id'", j.args) in ^meeting_ids or
                fragment("?->>'poll_id'", j.args) == ^poll.id
          )
        )

        Repo.delete_all(from(p in PollSchema, where: p.user_id == ^user.id))
        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user, poll: poll, slot: slot}
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

  defp committed_poll(poll), do: unboxed(fn -> Repo.get!(PollSchema, poll.id) end)

  defp committed_meetings(user) do
    unboxed(fn ->
      Repo.aggregate(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id), :count)
    end)
  end
end
