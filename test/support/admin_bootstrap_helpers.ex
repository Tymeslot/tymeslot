defmodule Tymeslot.Test.AdminBootstrapHelpers do
  @moduledoc """
  The first-user admin bootstrap in tests.

  A migrated test database has no users, so its bootstrap is open, and every
  sign-up in the suite would take the bootstrap's global advisory lock and
  hold it until its test's sandbox transaction ends, serialising sign-ups
  across async tests. `close!/0` runs once from `test_helper.exs`, outside the
  sandbox, so the suite runs as an established install does: sign-ups read the
  flag and never touch the lock.

  A test about the first user becoming admin reopens the bootstrap inside its
  own transaction with `reopen/1` (usable as `setup :reopen_admin_bootstrap`),
  which the sandbox rolls back afterwards.
  """

  import Ecto.Query, only: [from: 2]

  alias Tymeslot.AppSettings.{AppSettingsQueries, AppSettingsSchema}
  alias Tymeslot.Repo

  @doc """
  Marks the test database's bootstrap as closed. Idempotent, and run by each
  test partition against its own database.
  """
  @spec close!() :: :ok
  def close!, do: AppSettingsQueries.mark_admin_bootstrapped()

  @doc """
  Reopens the bootstrap. Inside a sandboxed test the change is rolled back
  with the test; outside one it persists, so pair it with `close!/0`.
  """
  @spec reopen_admin_bootstrap(map()) :: :ok
  def reopen_admin_bootstrap(_context \\ %{}) do
    Repo.update_all(from(s in AppSettingsSchema, where: s.id == 1),
      set: [admin_bootstrapped_at: nil]
    )

    :ok
  end
end
