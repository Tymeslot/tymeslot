defmodule Tymeslot.Auth.AdminBootstrap do
  @moduledoc """
  First-user-becomes-admin bootstrap for self-hosted installs.

  The first user to register on a fresh install is promoted to admin in the
  same transaction as their insert. The bootstrap then closes for good: the
  `admin_bootstrapped_at` timestamp on the `app_settings` singleton is set in
  that transaction, and while it is set nobody else is promoted this way.
  Further admins come only from an existing admin or from
  `mix tymeslot.promote_admin` / `Tymeslot.Release.promote_admin/1`.

  The timestamp is what makes the gate one-way. Deciding by "is this user the
  only row in the table?" alone reopened it whenever the table emptied again,
  so if the sole user deleted their account, the next stranger to sign up
  became admin. Installs that already had users when the column was added are
  marked bootstrapped by its migration.

  Concurrent first sign-ups are serialised by a transaction-scoped advisory
  lock taken before the timestamp is read: the second waits for the first to
  commit and then finds the bootstrap closed, so exactly one becomes admin.
  """

  require Logger

  alias Tymeslot.AppSettings.AppSettingsQueries
  alias Tymeslot.Auth.{UserQueries, UserSchema}
  alias Tymeslot.Repo

  @doc """
  Promotes `user` to admin if the install has not been bootstrapped yet and
  `user` is its only user, and closes the bootstrap either way. Once closed,
  returns the user unchanged.

  Call it in the same transaction as the user insert: the advisory lock it
  takes is held until that transaction ends, which is what serialises
  concurrent sign-ups. Called outside a transaction it opens its own, which is
  safe but serialises nothing beyond this call. Two calling conventions are
  supported:

    * **Explicit repo** (recommended when using `Repo.transaction(fn repo -> end)`):
      pass the transaction's repo as the second argument so all queries in the
      callback use the same checked-out connection.

    * **Implicit Repo** (acceptable when calling from `Repo.transaction(fn -> end)`
      on the same process): omit the second argument. Ecto tracks the checked-out
      connection via the process dictionary, so the default `Repo` resolves to the
      same connection automatically.
  """
  @spec maybe_promote_first_user(UserSchema.t(), module()) ::
          {:ok, UserSchema.t()} | {:error, Ecto.Changeset.t()}
  def maybe_promote_first_user(%UserSchema{} = user, repo \\ Repo) do
    repo.transaction(fn ->
      AppSettingsQueries.lock_admin_bootstrap(repo)

      if AppSettingsQueries.admin_bootstrapped?(repo) do
        user
      else
        AppSettingsQueries.mark_admin_bootstrapped(repo)
        promote_if_only_user(user, repo)
      end
    end)
  end

  # Kept alongside the timestamp: an install that reaches its first bootstrap
  # with users already present (created by a path that skips this module) has
  # no first user to promote.
  defp promote_if_only_user(user, repo) do
    if UserQueries.only_user?(user, repo) do
      case UserQueries.set_admin(user, true, repo) do
        {:ok, promoted} ->
          Logger.info("Promoted first registered user to admin", user_id: promoted.id)
          promoted

        {:error, changeset} ->
          repo.rollback(changeset)
      end
    else
      user
    end
  end

  @doc """
  Logs a warning when the database has users but no admins. Surfaced at
  application start so the operator notices a "stranded" install — typically
  the result of demoting every admin or restoring a backup from before the
  is_admin column was populated. Recovery is `mix tymeslot.promote_admin
  <email>` (or `bin/tymeslot rpc` in production releases).
  """
  @spec warn_if_orphaned_install() :: :ok
  def warn_if_orphaned_install do
    if UserQueries.any_user?() and not UserQueries.any_admin?() do
      Logger.warning(
        "No admin users exist. Promote one with `mix tymeslot.promote_admin <email>` " <>
          "or `bin/tymeslot rpc 'Tymeslot.Release.promote_admin(\"<email>\")'`."
      )
    end

    :ok
  rescue
    error ->
      Logger.error("Admin bootstrap check failed", reason: inspect(error))
      :ok
  end
end
