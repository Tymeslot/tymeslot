defmodule Tymeslot.Auth.AdminUserQueries do
  @moduledoc """
  Queries over the `users` table for admin roles: listing and counting users
  and admins, the first-user bootstrap checks, the sign-in-capable-admin
  lockout guards, and setting the `is_admin` flag.

  Account lookups and credential writes live in `Tymeslot.Auth.UserQueries`.
  """
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo

  @doc """
  Lists all users in the system, ordered by id ascending.
  Profiles are preloaded so callers (e.g. the admin users tab) can show
  booking slug and display name without N+1 queries.
  Returns a list of user records (can be empty).
  """
  @spec list_all_users() :: [UserSchema.t()]
  def list_all_users do
    Repo.all(from(u in UserSchema, order_by: u.id, preload: [:profile]))
  end

  @doc """
  Returns `true` if `user` is the only row in the `users` table.

  Requires an explicit `repo` argument: the call site runs this inside the
  same transaction as the insert it is gating, so the visibility check happens
  against the just-inserted row.

  On its own this does not make the "first user becomes admin" bootstrap
  race-free: under READ COMMITTED two concurrent signups on a brand-new
  install can each see only their own row. `Tymeslot.Auth.AdminBootstrap`
  closes that gap with an atomic claim on the settings row taken before this
  check.
  """
  @spec only_user?(UserSchema.t(), module()) :: boolean()
  def only_user?(%UserSchema{id: id}, repo) do
    not repo.exists?(from(u in UserSchema, where: u.id != ^id, select: 1, limit: 1))
  end

  @doc """
  Returns `true` if at least one row in `users` has `is_admin = true`.
  """
  @spec any_admin?(module()) :: boolean()
  def any_admin?(repo \\ Repo) do
    repo.exists?(from(u in UserSchema, where: u.is_admin, select: 1, limit: 1))
  end

  @doc """
  Returns `true` if at least one admin can actually sign in with email +
  password today.

  Mirrors the gate `Tymeslot.Auth.Authentication.verify_user_password/2`
  applies at login: a `password_hash` alone is not enough — the account must
  also not be OAuth-only (`provider` is `nil`/`"email"`) and must be verified
  (`verified_at` set), or the login attempt is rejected before the password
  is even checked. Counting an admin who cannot pass that gate would let the
  lockout guard in `Tymeslot.AppSettings.LockoutPolicy` permit disabling the
  last working sign-in path. If `verify_user_password/2`'s conditions change,
  this query must change with them.
  """
  @spec any_admin_uses_password_auth?(module()) :: boolean()
  def any_admin_uses_password_auth?(repo \\ Repo) do
    repo.exists?(
      from(u in UserSchema,
        where:
          u.is_admin and
            not is_nil(u.password_hash) and
            not is_nil(u.verified_at) and
            (is_nil(u.provider) or u.provider == "email"),
        select: 1,
        limit: 1
      )
    )
  end

  @doc """
  Counts admins, other than `excluded_user_id`, who can actually sign in
  today: password-capable per `any_admin_uses_password_auth?/1`'s criteria,
  or authenticated via one of `usable_sso_providers` (`:google`, `:github`,
  `:oauth`).

  `usable_sso_providers` is data, not a config lookup: callers (see
  `Tymeslot.Release.check_last_admin/2`) pass only the providers already
  confirmed enabled *and* credential-configured system-wide, mirroring
  `Tymeslot.AppSettings.LockoutPolicy`'s "usable auth path" definition. This
  keeps the query module free of `AppSettings` reads while still refusing to
  count an SSO identity nobody can currently use to log in.

  Used to guard demoting the last admin: counting bare `is_admin` rows (as
  `count_admins/1` does) would let an operator demote the only admin who can
  actually authenticate, as long as some other `is_admin` row happens to
  exist without a usable sign-in path.
  """
  @spec count_signin_capable_admins_excluding(integer(), [atom()], module()) :: non_neg_integer()
  def count_signin_capable_admins_excluding(
        excluded_user_id,
        usable_sso_providers,
        repo \\ Repo
      ) do
    password_capable =
      dynamic(
        [u],
        not is_nil(u.password_hash) and not is_nil(u.verified_at) and
          (is_nil(u.provider) or u.provider == "email")
      )

    sso_capable = sso_capable_condition(usable_sso_providers)

    condition =
      dynamic(
        [u],
        u.is_admin and u.id != ^excluded_user_id and (^password_capable or ^sso_capable)
      )

    repo.aggregate(
      from(u in UserSchema, where: ^condition),
      :count,
      :id
    )
  end

  defp sso_capable_condition(usable_sso_providers) do
    Enum.reduce(usable_sso_providers, dynamic(false), fn
      :google, acc -> dynamic([u], ^acc or not is_nil(u.google_user_id))
      :github, acc -> dynamic([u], ^acc or not is_nil(u.github_user_id))
      :oauth, acc -> dynamic([u], ^acc or (u.provider == "oauth" and not is_nil(u.provider_uid)))
      _other, acc -> acc
    end)
  end

  @doc """
  Returns `true` if the `users` table has at least one row.
  """
  @spec any_user?(module()) :: boolean()
  def any_user?(repo \\ Repo) do
    repo.exists?(from(u in UserSchema, select: 1, limit: 1))
  end

  @doc """
  Sets `is_admin` on a user. Internal-only — callers must have already
  verified that the actor is authorised to make this change.

  Accepts an optional `repo` argument for use within transactions.
  """
  @spec set_admin(UserSchema.t(), boolean(), module()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def set_admin(%UserSchema{} = user, is_admin, repo \\ Repo) when is_boolean(is_admin) do
    user
    |> UserSchema.admin_changeset(is_admin)
    |> repo.update()
  end

  @doc """
  Returns every admin user, ordered by id.
  """
  @spec list_admins(module()) :: [UserSchema.t()]
  def list_admins(repo \\ Repo) do
    repo.all(from(u in UserSchema, where: u.is_admin, order_by: u.id))
  end

  @doc """
  Acquires a `FOR UPDATE` row lock on every admin user and returns them.

  Must be called inside a transaction. Used by `AdminRoles` to prevent
  concurrent demotions from racing past the last-admin invariant.
  """
  @spec lock_admins() :: [UserSchema.t()]
  def lock_admins do
    Repo.all(from(u in UserSchema, where: u.is_admin == true, lock: "FOR UPDATE"))
  end

  @doc """
  Counts users in the table.
  """
  @spec count_users(module()) :: non_neg_integer()
  def count_users(repo \\ Repo) do
    repo.aggregate(UserSchema, :count, :id)
  end

  @doc """
  Counts admin users.
  """
  @spec count_admins(module()) :: non_neg_integer()
  def count_admins(repo \\ Repo) do
    repo.aggregate(from(u in UserSchema, where: u.is_admin), :count, :id)
  end
end
