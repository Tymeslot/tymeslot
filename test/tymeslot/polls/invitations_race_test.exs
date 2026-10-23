defmodule Tymeslot.Polls.InvitationsRaceTest do
  @moduledoc """
  A host inviting an address while the same address asks for a link on the
  voting page, run on real connections staged by `Tymeslot.Test.RaceConductor`
  (see its moduledoc for why the module is synchronous and why `on_exit`
  deletes what it committed).
  """

  use Tymeslot.DataCase, async: false

  @moduletag :polls
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [unboxed: 1]

  alias Ecto.Adapters.SQL
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantSchema, Voting}
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  setup do
    %{rows: [[last_job_id]]} =
      unboxed(fn -> SQL.query!(Repo, "SELECT coalesce(max(id), 0) FROM oban_jobs", []) end)

    poll =
      unboxed(fn ->
        user = insert(:user)
        insert(:profile, user: user, username: "host#{System.unique_integer([:positive])}")
        insert(:poll, user: user, status: :open)
      end)

    on_exit(fn ->
      unboxed(fn ->
        SQL.query!(Repo, "DELETE FROM oban_jobs WHERE id > $1", [last_job_id])
        SQL.query!(Repo, "DELETE FROM users WHERE id = $1", [poll.user_id])
      end)
    end)

    RaceConductor.attach_parking()

    %{poll: poll}
  end

  test "a request for an address the host is inviting ends as one invited participant", %{
    poll: poll
  } do
    test_pid = self()
    entries = [%{email: "ada@example.com", name: "Ada"}]

    host =
      Task.async(fn ->
        unboxed(fn ->
          RaceConductor.arm(RaceConductor.park_here(test_pid), &address_lock?/1)
          Polls.invite_participants(poll.id, poll.user_id, entries)
        end)
      end)

    # The host has found nobody under the address and not yet written them.
    assert_receive {:parked, host_pid}, 5_000

    voter =
      Task.async(fn ->
        unboxed(fn -> Voting.request_link(poll, %{name: "Ada L", email: "ada@example.com"}) end)
      end)

    # The request waits for the host's invitations rather than writing its
    # row under them.
    assert RaceConductor.await_finished_or_blocked(voter) == :blocked

    send(host_pid, :release)

    assert {:ok, %{invited: [%PollParticipantSchema{email: "ada@example.com"} = invited]}} =
             Task.await(host)

    # It then meets the address as one whose link has just gone out.
    assert Task.await(voter) == {:ok, :throttled}

    assert [participant] =
             unboxed(fn ->
               Repo.all(from(p in PollParticipantSchema, where: p.poll_id == ^poll.id))
             end)

    assert participant.id == invited.id
    assert %DateTime{} = participant.confirmed_at
    assert %DateTime{} = participant.invited_at
    assert participant.name == "Ada"
  end

  # The host's locking read of the addresses already on the poll.
  defp address_lock?(metadata) do
    metadata[:source] == "poll_participants" and metadata[:query] =~ "FOR UPDATE" and
      metadata[:query] =~ ~s("email" = )
  end
end
