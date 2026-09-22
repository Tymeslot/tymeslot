defmodule Tymeslot.Infrastructure.HealthQueries do
  @moduledoc """
  The database probe behind `Tymeslot.Infrastructure.Health`.

  Lives here rather than inline because every `Repo.*` call other than
  `transaction`, `rollback` and `preload` belongs in a `*_queries.ex` module
  (`CredoChecks.RepoCallBoundary`).
  """

  alias Tymeslot.Repo

  # Bounded so a wedged database fails the healthcheck instead of hanging it
  # past the orchestrator's own probe timeout.
  @timeout :timer.seconds(5)

  @doc """
  Runs a trivial round trip against the database.
  """
  @spec ping() :: :ok | {:error, term()}
  def ping do
    case Repo.query("SELECT 1", [], timeout: @timeout) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
