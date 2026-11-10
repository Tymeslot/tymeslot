defmodule Tymeslot.Test.EnqueuedJobs do
  @moduledoc """
  The jobs a test enqueued, without those a process left over from an
  earlier test enqueued into its sandbox.

  A sync (`async: false`) test shares its sandbox connection with every
  process, so a LiveView or task an earlier test started, and that outlives
  it, can still insert a job that `all_enqueued/0` then returns: the nightly
  flake hunt caught a dashboard's stale-calendar refresh landing in a later
  test this way. Such a job names its own test's user, in its args or in the
  `meta["user_id"]` the Oban engine stamps
  (`Tymeslot.Infrastructure.ObanEngine.inherited_context/1`), so
  `for_user/1` leaves out every job naming a user other than the given one.

  A job naming no user is kept. Leaving it out would let an assertion that
  nothing was enqueued pass over a regression that enqueues one.
  """

  alias Oban.Testing
  alias Tymeslot.Infrastructure.ObanEngine
  alias Tymeslot.Repo

  @doc "Every enqueued job except those naming a user other than `user`."
  @spec for_user(%{id: integer()} | integer()) :: [Oban.Job.t()]
  def for_user(%{id: user_id}), do: for_user(user_id)

  def for_user(user_id) when is_integer(user_id) do
    [repo: Repo]
    |> Testing.all_enqueued()
    |> Enum.reject(&foreign?(&1, user_id))
  end

  defp foreign?(job, user_id) do
    case Keyword.fetch(ObanEngine.inherited_context(job), :user_id) do
      {:ok, named} -> to_string(named) != to_string(user_id)
      :error -> false
    end
  end
end
