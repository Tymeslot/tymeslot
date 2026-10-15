defmodule Tymeslot.Analytics.SaltQueries do
  @moduledoc """
  Data access for `analytics_salts`, the random per-UTC-day salts behind the
  analytics visitor hash.

  All `Repo.*` calls for analytics salts live here per the
  `CredoChecks.RepoCallBoundary` rule.
  """
  import Ecto.Query

  alias Tymeslot.Analytics.SaltSchema
  alias Tymeslot.Repo

  @salt_bytes 32

  @doc """
  Returns the salt for `date`, creating a random one if the day has none yet.

  The insert does nothing on conflict and the row is then read back, so when
  several nodes or processes reach a new day at once, every one of them ends up
  with the salt of whichever insert won.
  """
  @spec get_or_create(Date.t()) :: binary()
  def get_or_create(%Date{} = date) do
    Repo.insert_all(
      SaltSchema,
      [%{date: date, salt: :crypto.strong_rand_bytes(@salt_bytes)}],
      on_conflict: :nothing,
      conflict_target: :date
    )

    Repo.one!(from(s in SaltSchema, where: s.date == ^date, select: s.salt))
  end

  @doc """
  Deletes the salts of every day before `date`. Returns the `{deleted_count,
  nil}` tuple from `delete_all`.
  """
  @spec delete_before(Date.t()) :: {non_neg_integer(), nil}
  def delete_before(%Date{} = date) do
    SaltSchema
    |> where([s], s.date < ^date)
    |> Repo.delete_all()
  end
end
