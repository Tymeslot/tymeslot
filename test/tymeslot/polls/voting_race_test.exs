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
  alias Tymeslot.Polls.{PollParticipantSchema, Voting}
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  setup do
    poll = unboxed(fn -> insert(:poll) end)

    on_exit(fn ->
      unboxed(fn ->
        SQL.query!(
          Repo,
          """
          DELETE FROM oban_jobs WHERE args->>'participant_id' IN
            (SELECT id::text FROM poll_participants WHERE poll_id = $1)
          """,
          [Ecto.UUID.dump!(poll.id)]
        )

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

  # The lookup of the address on the poll: both contenders park right after
  # it, so each misses the other's row and both go on to insert.
  defp address_lookup?(metadata) do
    metadata[:source] == "poll_participants" and
      String.starts_with?(metadata[:query], "SELECT") and
      metadata[:query] =~ ~s("email" = )
  end
end
