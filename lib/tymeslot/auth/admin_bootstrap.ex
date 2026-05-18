defmodule Tymeslot.Auth.AdminBootstrap do
  @moduledoc """
  First-user-becomes-admin bootstrap for self-hosted installs.

  When the very first user registers on a fresh install (the `users` table is
  empty up to the moment of their insert), they are promoted to admin in the
  same transaction. Once any user exists, the gate stays closed permanently
  — additional admins can only be promoted via `mix tymeslot.promote_admin`
  or `Tymeslot.Release.promote_admin/1`.

  The check is performed *after* the insert by asking "is this user the only
  row in the table?". This makes the bootstrap idempotent against the race
  where two signups arrive in quick succession on a brand-new install: at
  worst both become admin, which is acceptable because both belong to the
  operator setting up a fresh instance.
  """

  require Logger

  alias Tymeslot.Auth.{UserQueries, UserSchema}
  alias Tymeslot.Repo

  @doc """
  If `user` is the only row in the `users` table, promote them to admin.
  Otherwise, return the user unchanged.

  Must be called inside the same transaction as the user insert so the
  visibility check happens against uncommitted state. Two calling conventions
  are supported:

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
    if UserQueries.only_user?(user, repo) do
      case UserQueries.set_admin(user, true, repo) do
        {:ok, promoted} ->
          Logger.info("Promoted first registered user to admin", user_id: promoted.id)
          {:ok, promoted}

        {:error, _changeset} = error ->
          error
      end
    else
      {:ok, user}
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
