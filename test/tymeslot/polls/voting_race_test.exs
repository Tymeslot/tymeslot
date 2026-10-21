defmodule Tymeslot.Polls.VotingRaceTest do
  @moduledoc """
  Races on the public voting path, run on real connections staged by
  `Tymeslot.Test.RaceConductor` (see its moduledoc for why the module is
  synchronous and why `on_exit` deletes what it committed).
  """

  use Tymeslot.DataCase, async: false

  @moduletag :polls
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Ecto.Adapters.SQL
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantSchema, PollVoteSchema, Voting}
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  setup do
    # Jobs are matched by id rather than by participant: a test that removes
    # a participant would otherwise leave that participant's committed jobs
    # behind for later modules' `refute_enqueued` to find.
    %{rows: [[last_job_id]]} =
      unboxed(fn -> SQL.query!(Repo, "SELECT coalesce(max(id), 0) FROM oban_jobs", []) end)

    poll = unboxed(fn -> insert(:poll) end)

    on_exit(fn ->
      unboxed(fn ->
        SQL.query!(Repo, "DELETE FROM oban_jobs WHERE id > $1", [last_job_id])

        SQL.query!(Repo, "DELETE FROM users WHERE id = $1", [poll.user_id])
      end)
    end)

    RaceConductor.attach_parking()

    %{poll: poll}
  end

  test "two requests for a new address at once make one participant and send one link", %{
    poll: poll
  } do
    attrs = %{name: "Ada", email: "ada@example.com"}

    results =
      race(
        for _contender <- 1..2 do
          fn hold ->
            RaceConductor.arm(hold, &address_lookup?/1, must_park: true)
            Voting.request_link(poll, attrs)
          end
        end
      )

    # Both missed the other's row; the loser hit the unique index and was
    # answered as a request for a known address, whose link had just gone out.
    assert Enum.sort(results) == [{:ok, :sent}, {:ok, :throttled}]

    {participants, link_jobs} =
      unboxed(fn ->
        participants = Repo.all(from(p in PollParticipantSchema, where: p.poll_id == ^poll.id))
        ids = Enum.map(participants, &to_string(&1.id))

        jobs =
          Repo.all(
            from(j in Oban.Job,
              where:
                fragment("?->>'action'", j.args) == "send_poll_participant_link" and
                  fragment("?->>'participant_id'", j.args) in ^ids
            )
          )

        {participants, jobs}
      end)

    assert [%{email: "ada@example.com"}] = participants
    assert [_one_link] = link_jobs
  end

  test "a voter removed between opening their link and saving is told the link is gone", %{
    poll: poll
  } do
    {participant, slot, loaded} =
      unboxed(fn ->
        slot = insert(:poll_time_slot, poll: poll)
        participant = insert(:poll_participant, poll: poll, name: "Grace")
        {:ok, loaded} = Polls.get_poll_for_voting(poll.token)
        {participant, slot, loaded}
      end)

    parent = self()

    hold = fn _arg ->
      send(parent, {:parked, self()})

      receive do
        :release -> {:ok, :released}
      end
    end

    voter =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(hold, &token_lookup?/1)
          Voting.cast_votes(loaded, participant.token, %{slot.id => "yes"})
        end)
      end)

    # The voter has resolved their link; the host removes them before the
    # votes are written.
    assert_receive {:parked, voter_pid}, 5_000

    assert :ok =
             unboxed(fn -> Polls.remove_participant(poll.id, poll.user_id, participant.id) end)

    send(voter_pid, :release)

    assert {:error, :unknown_participant} = Task.await(voter)
  end

  test "a host removing a voter waits for the votes being saved, then takes them with the voter",
       %{
         poll: poll
       } do
    {participant, slot, loaded} =
      unboxed(fn ->
        slot = insert(:poll_time_slot, poll: poll)
        participant = insert(:poll_participant, poll: poll, name: "Grace")
        {:ok, loaded} = Polls.get_poll_for_voting(poll.token)
        {participant, slot, loaded}
      end)

    parent = self()

    hold = fn _arg ->
      send(parent, {:parked, self()})

      receive do
        :release -> {:ok, :released}
      end
    end

    voter =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(hold, RaceConductor.lock_of("poll_participants"))
          Voting.cast_votes(loaded, participant.token, %{slot.id => "yes"})
        end)
      end)

    # The voter holds the participant's row and has not yet written votes.
    assert_receive {:parked, voter_pid}, 5_000

    removal =
      Task.async(fn ->
        unboxed(fn -> Polls.remove_participant(poll.id, poll.user_id, participant.id) end)
      end)

    # The removal queues behind the voter's lock.
    assert Task.yield(removal, 500) == nil

    send(voter_pid, :release)

    assert {:ok, %PollParticipantSchema{}} = Task.await(voter)
    assert :ok = Task.await(removal)

    {participants, votes} =
      unboxed(fn ->
        {Repo.all(from(p in PollParticipantSchema, where: p.poll_id == ^poll.id)),
         Repo.all(from(v in PollVoteSchema, where: v.poll_participant_id == ^participant.id))}
      end)

    assert participants == []
    assert votes == []
  end

  # The token lookup `cast_votes/4` starts with.
  defp token_lookup?(metadata) do
    metadata[:source] == "poll_participants" and metadata[:query] =~ ~s("token_hash" = )
  end

  # The lookup of the address on the poll: both contenders park right after
  # it, so each misses the other's row and both go on to insert.
  defp address_lookup?(metadata) do
    metadata[:source] == "poll_participants" and
      String.starts_with?(metadata[:query], "SELECT") and
      metadata[:query] =~ ~s("email" = )
  end
end
