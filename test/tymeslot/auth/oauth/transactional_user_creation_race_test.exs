defmodule Tymeslot.Auth.OAuth.TransactionalUserCreationRaceTest do
  @moduledoc """
  Two requests creating the same OAuth identity at once: the second misses the
  lookup (the first has not committed), blocks on the unique index, and must
  end with the first request's account rather than an error.

  The race needs two real transactions, which the sandbox cannot give (every
  process shares its one connection), so it runs unboxed and deletes what it
  writes.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :integration

  import Tymeslot.TestHelpers.Eventually

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Auth.OAuth.TransactionalUserCreation
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Repo

  test "a concurrent insert of the same identity returns the account that won" do
    uid = "race-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> SQL.query!(Repo, "DELETE FROM users WHERE github_user_id = $1", [uid]) end)
    end)

    parent = self()

    winner =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            {:ok, user} =
              UserQueries.create_social_user(%{
                "email" => "#{uid}-first@example.com",
                "provider" => "github",
                "github_user_id" => uid
              })

            send(parent, {:inserted, user.id})
            receive do: (:commit -> user.id)
          end)
        end)
      end)

    assert_receive {:inserted, winner_id}, 5_000

    loser =
      Task.async(fn ->
        unboxed(fn ->
          TransactionalUserCreation.find_or_create_oauth_user(:github, %{
            "email" => "#{uid}-second@example.com",
            "provider" => "github",
            "github_user_id" => uid
          })
        end)
      end)

    # Commit the winner only once the loser is blocked on the unique index.
    eventually(fn -> assert waiting_on_lock?() end)
    send(winner.pid, :commit)

    assert {:ok, ^winner_id} = Task.await(winner)
    assert {:ok, %{user: %{id: ^winner_id}, created: false}} = Task.await(loser)
  end

  defp waiting_on_lock? do
    %{rows: [[count]]} =
      unboxed(fn ->
        SQL.query!(
          Repo,
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'",
          []
        )
      end)

    count > 0
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
