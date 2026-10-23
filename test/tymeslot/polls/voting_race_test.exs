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
  alias Tymeslot.Polls.{PollParticipantSchema, PollQueries, PollVoteSchema, Voting}
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

    {participants, link_jobs} = unboxed(fn -> participants_and_link_jobs(poll) end)

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

  test "a vote on a poll the host cancelled after the page loaded is refused and saves nothing",
       %{poll: poll} do
    {participant, slot, loaded} = voter_on(poll)
    test_pid = self()

    voter =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(RaceConductor.park_here(test_pid), &token_lookup?/1)
          Voting.cast_votes(loaded, participant.token, %{slot.id => "yes"})
        end)
      end)

    # The voter has passed the check against the page's copy of the poll; the
    # host cancels it before the votes are written.
    assert_receive {:parked, voter_pid}, 5_000

    assert {:ok, %{status: :cancelled}} =
             unboxed(fn -> Polls.cancel_poll(poll.id, poll.user_id) end)

    send(voter_pid, :release)

    assert {:error, :voting_closed} = Task.await(voter)
    assert unboxed(fn -> votes_of(participant) end) == []
  end

  test "a host cancelling a poll waits for the vote being saved, then closes it", %{poll: poll} do
    {participant, slot, loaded} = voter_on(poll)
    test_pid = self()

    voter =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(RaceConductor.park_here(test_pid), &poll_share_lock?/1)
          Voting.cast_votes(loaded, participant.token, %{slot.id => "yes"})
        end)
      end)

    # The voter holds the poll's row and has not yet locked themselves.
    assert_receive {:parked, voter_pid}, 5_000

    cancel = Task.async(fn -> unboxed(fn -> Polls.cancel_poll(poll.id, poll.user_id) end) end)

    # The cancellation queues behind the vote's share lock.
    assert Task.yield(cancel, 500) == nil

    send(voter_pid, :release)

    assert {:ok, %PollParticipantSchema{}} = Task.await(voter)
    assert {:ok, %{status: :cancelled}} = Task.await(cancel)
    assert [%PollVoteSchema{response: :yes}] = unboxed(fn -> votes_of(participant) end)
  end

  test "a request for a known address pruned before its link is claimed starts over as new", %{
    poll: poll
  } do
    # A link went out moments ago, so were the row still there the request
    # would be answered as a repeat inside the resend window.
    pending =
      unboxed(fn ->
        insert(:poll_participant,
          poll: poll,
          name: "Ada",
          email: "ada@example.com",
          confirmed_at: nil,
          invited_at: nil,
          link_sent_at: DateTime.utc_now(:second)
        )
      end)

    test_pid = self()

    request =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(RaceConductor.park_here(test_pid), &address_lookup?/1)
          Voting.request_link(poll, %{name: "Ada", email: "ada@example.com"})
        end)
      end)

    # The request has found Ada's row; the retention worker prunes it before
    # the send is claimed, so the claim touches nothing.
    assert_receive {:parked, request_pid}, 5_000
    unboxed(fn -> Repo.delete!(Repo.get!(PollParticipantSchema, pending.id)) end)
    send(request_pid, :release)

    assert {:ok, :sent} = Task.await(request)

    {participants, link_jobs} = unboxed(fn -> participants_and_link_jobs(poll) end)

    assert [%{email: "ada@example.com", confirmed_at: nil} = fresh] = participants
    refute fresh.id == pending.id
    assert [%{args: %{"participant_id" => fresh_id}}] = link_jobs
    assert fresh_id == to_string(fresh.id)
  end

  test "a link request overtaken by the switch to invite-only is refused and leaves no row", %{
    poll: poll
  } do
    test_pid = self()

    request =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(RaceConductor.park_here(test_pid), &address_lookup?/1)
          Voting.request_link(poll, %{name: "Ada", email: "ada@example.com"})
        end)
      end)

    # The request has passed the invite-only check and found no row for the
    # address; the host shuts the door before it writes one.
    assert_receive {:parked, request_pid}, 5_000

    assert {:ok, _switched} =
             unboxed(fn ->
               Polls.update_details(poll.id, poll.user_id, %{"invite_only" => true})
             end)

    send(request_pid, :release)

    assert {:error, :invite_only} = Task.await(request)
    assert {[], []} = unboxed(fn -> participants_and_link_jobs(poll) end)
  end

  test "deleting a poll while a vote is being saved waits for the vote, then takes it with the poll",
       %{poll: poll} do
    {participant, slot, loaded} = voter_on(poll)
    test_pid = self()

    voter =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(
            RaceConductor.park_here(test_pid),
            RaceConductor.lock_of("poll_participants")
          )

          Voting.cast_votes(loaded, participant.token, %{slot.id => "yes"})
        end)
      end)

    # The voter holds the poll `FOR SHARE` and their own row `FOR UPDATE`.
    assert_receive {:parked, voter_pid}, 5_000

    # The host cannot delete a poll still open, so their own delete never
    # meets a vote in progress; it is refused without waiting.
    assert {:error, :still_open} =
             unboxed(fn -> Polls.delete_poll(poll.id, poll.user_id) end)

    # The cascade every poll delete runs (the host's on a closed poll, the
    # account deletion's on any) queues behind the vote's lock on the poll.
    deletion = Task.async(fn -> unboxed(fn -> PollQueries.delete(poll) end) end)
    assert RaceConductor.await_finished_or_blocked(deletion) == :blocked

    send(voter_pid, :release)

    assert {:ok, %PollParticipantSchema{}} = Task.await(voter)
    assert {:ok, _deleted} = Task.await(deletion)

    assert {[], _no_jobs} = unboxed(fn -> participants_and_link_jobs(poll) end)
    assert unboxed(fn -> votes_of(participant) end) == []
  end

  test "a vote arriving while the host deletes the poll waits, then is refused cleanly", %{
    poll: poll
  } do
    # The voter's page loaded while the poll was open; the host has since
    # cancelled it and now deletes it.
    {participant, slot, loaded} = voter_on(poll)
    assert {:ok, _cancelled} = unboxed(fn -> Polls.cancel_poll(poll.id, poll.user_id) end)
    test_pid = self()

    deletion =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(RaceConductor.park_here(test_pid), &poll_delete?/1)
          Repo.transaction(fn -> Polls.delete_poll(poll.id, poll.user_id) end)
        end)
      end)

    # The delete has removed the poll and, by cascade, its participants and
    # slots, and holds those rows until it commits.
    assert_receive {:parked, deletion_pid}, 5_000

    voter =
      Task.async(fn ->
        unboxed(fn -> Voting.cast_votes(loaded, participant.token, %{slot.id => "yes"}) end)
      end)

    assert RaceConductor.await_finished_or_blocked(voter) == :blocked

    send(deletion_pid, :release)

    assert {:ok, :ok} = Task.await(deletion)
    assert {:error, :voting_closed} = Task.await(voter)
    assert unboxed(fn -> votes_of(participant) end) == []
  end

  defp participants_and_link_jobs(poll) do
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
  end

  defp voter_on(poll) do
    unboxed(fn ->
      slot = insert(:poll_time_slot, poll: poll)
      participant = insert(:poll_participant, poll: poll, name: "Grace")
      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)
      {participant, slot, loaded}
    end)
  end

  defp votes_of(participant),
    do: Repo.all(from(v in PollVoteSchema, where: v.poll_participant_id == ^participant.id))

  # The vote's read of the poll under its share lock.
  defp poll_share_lock?(metadata) do
    metadata[:source] == "polls" and metadata[:query] =~ "FOR SHARE"
  end

  # The host's delete of the poll row, which cascades to its children.
  defp poll_delete?(metadata) do
    metadata[:source] == "polls" and String.starts_with?(metadata[:query], "DELETE")
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
