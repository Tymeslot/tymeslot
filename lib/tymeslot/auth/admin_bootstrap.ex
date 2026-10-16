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

  Closing it is an atomic claim (`AppSettingsQueries.claim_admin_bootstrap/1`):
  of two concurrent first sign-ups, the second waits for the first to commit
  and then finds nothing to claim, so exactly one can be promoted. Once the
  bootstrap is closed, a sign-up sees so from a plain read and returns at
  once, so an established install never contends for the settings row.
  """

  require Logger

  alias Tymeslot.AppSettings.{AppSettingsQueries, Env}
  alias Tymeslot.Auth.{AdminUserQueries, UserSchema}
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Repo

  @doc """
  Promotes `user` to admin if the install has not been bootstrapped yet and
  `user` is its only user, and closes the bootstrap either way. Once closed,
  returns the user unchanged.

  Call it in the same transaction as the user insert, so the claim and the
  "only user" check are committed or rolled back with it. Called outside a
  transaction it opens its own. Two calling conventions are supported:

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
    # Fast path: once closed the bootstrap never reopens, so an established
    # install answers from a plain read.
    if AppSettingsQueries.admin_bootstrapped?(repo) do
      {:ok, user}
    else
      repo.transaction(fn ->
        if AppSettingsQueries.claim_admin_bootstrap(repo) do
          promote_if_only_user(user, repo)
        else
          user
        end
      end)
    end
  end

  # Kept alongside the timestamp: an install that reaches its first bootstrap
  # with users already present (created by a path that skips this module) has
  # no first user to promote.
  defp promote_if_only_user(user, repo) do
    if AdminUserQueries.only_user?(user, repo) do
      case AdminUserQueries.set_admin(user, true, repo) do
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
  Logs a warning at application start when nobody can administer the
  install, so the operator notices it is stranded:

    * users exist but none is an admin, typically after demoting every
      admin or restoring a backup from before the is_admin column was
      populated. Recovery is `Tymeslot.Release.promote_admin/1`.
    * the first-user bootstrap has run but no accounts are left, so the next
      sign-up will not become admin and, with registration closed, nobody
      can sign up at all. Recovery is `Tymeslot.Release.reopen_registration/0`,
      or setting `REGISTRATION_ENABLED=true` when that variable fixes the
      setting, followed by `promote_admin/1`.
  """
  @spec warn_if_orphaned_install() :: :ok
  def warn_if_orphaned_install do
    cond do
      AdminUserQueries.any_admin?() ->
        :ok

      AdminUserQueries.any_user?() ->
        Logger.warning(
          "No admin users exist. Promote one with `mix tymeslot.promote_admin <email>` " <>
            "or `bin/tymeslot rpc 'Tymeslot.Release.promote_admin(\"<email>\")'`."
        )

      AppSettingsQueries.admin_bootstrapped?() ->
        Logger.warning(
          "No accounts exist, and the first account to sign up will not become admin. " <>
            open_registration_step() <>
            ", sign up, then promote yourself with " <>
            "`bin/tymeslot rpc 'Tymeslot.Release.promote_admin(\"<email>\")'`."
        )

      true ->
        :ok
    end

    :ok
  rescue
    error ->
      Logger.error("Admin bootstrap check failed", reason: LogFormat.reason(error))
      :ok
  end

  # A variable that fixes registration also refuses the release helper's
  # write, so the way to open it is the variable itself.
  defp open_registration_step do
    case Env.pinned_var(:registration_enabled) do
      nil ->
        "Open registration with `bin/tymeslot rpc 'Tymeslot.Release.reopen_registration()'`"

      var ->
        "#{var} fixes registration, so open it by setting #{var}=true and restarting"
    end
  end
end
