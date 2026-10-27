defmodule Tymeslot.Auth.AdminRoles do
  @moduledoc """
  Domain logic for the admin role lifecycle.

  This module is the single entry point for promoting and demoting admin users.
  Both the LiveView admin UI and the CLI release helpers route through here,
  ensuring that all business rules (last-admin guard, audit logging) are
  applied consistently.

  Only two actors may change a role: a user who is an admin *now* (the flag is
  re-read from the database inside the transaction, so a stale struct from a
  long-lived session does not count) and `:cli`, the operator running a
  release or Mix task. Anyone else gets `{:error, :forbidden}`: the admin UI's
  `EnsureAdminHook` is not the only guard.

  Self-demotion is allowed for admin actors as long as at least one
  other admin who can actually sign in remains; the `:last_admin` guard is
  what prevents stranding the install. The guard applies to `:cli` too, but
  `:cli` alone may pass `force: true` to skip it, providing an operator
  escape hatch when the UI cannot be used (e.g. to remove a compromised sole
  admin before promoting a replacement).
  """

  require Logger

  alias Tymeslot.AppSettings.LockoutPolicy
  alias Tymeslot.Auth.{AdminUserQueries, UserQueries, UserSchema}
  alias Tymeslot.Repo

  @type actor :: UserSchema.t() | :cli

  @doc """
  Promotes the user identified by `target_user_id` to admin.

  Idempotent: if the user is already an admin, returns `{:ok, user}` without
  writing to the database.

  Returns:
    * `{:ok, %UserSchema{}}` on success (or if already admin)
    * `{:error, :admin_ui_disabled}` if the admin UI feature flag is off
    * `{:error, :forbidden}` if the actor is not a current admin or `:cli`
    * `{:error, :not_found}` if no user has that ID
    * `{:error, changeset}` if the database update fails
  """
  @spec promote(term(), pos_integer()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :forbidden | :admin_ui_disabled | Ecto.Changeset.t()}
  def promote(actor, target_user_id) do
    with :ok <- ensure_admin_ui_enabled() do
      Repo.transaction(fn ->
        # Locked as in demote/3, so the actor cannot be demoted between the
        # authorisation check and the promotion it allows.
        AdminUserQueries.lock_admins()
        authorise!(actor)

        case UserQueries.get_user(target_user_id) do
          {:error, :not_found} ->
            Repo.rollback(:not_found)

          {:ok, %UserSchema{is_admin: true} = target} ->
            target

          {:ok, target} ->
            case AdminUserQueries.set_admin(target, true) do
              {:ok, updated} ->
                log_role_change(:promote, actor, updated.id)
                updated

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
        end
      end)
    end
  end

  @doc """
  Demotes the user identified by `target_user_id` from admin.

  Self-demotion is allowed: an admin may demote themselves provided at least
  one other admin who can sign in will remain afterwards. The `:last_admin`
  guard below prevents stranding the install.

  Guard (skipped only for the `:cli` actor with `force: true`):
    * Returns `{:error, :last_admin}` when no other admin could sign in once
      the target is demoted: verified with a password, or linked to an SSO
      provider that is enabled and configured (checked inside a locked
      transaction to prevent races).

  Options:
    * `:force` - when `true` and the actor is `:cli`, skips the last-admin
      guard. Ignored for any other actor.

  Returns:
    * `{:ok, %UserSchema{}}` on success
    * `{:error, :admin_ui_disabled}` if the admin UI feature flag is off
    * `{:error, :forbidden}` if the actor is not a current admin or `:cli`
    * `{:error, :not_found}` if no user has that ID
    * `{:error, :last_admin}` if the target is the only admin who can sign in
    * `{:error, changeset}` if the database update fails
  """
  @spec demote(term(), pos_integer(), keyword()) ::
          {:ok, UserSchema.t()}
          | {:error,
             :not_found | :forbidden | :last_admin | :admin_ui_disabled | Ecto.Changeset.t()}
  def demote(actor, target_user_id, opts \\ []) do
    force? = actor == :cli and Keyword.get(opts, :force, false) == true

    with :ok <- ensure_admin_ui_enabled() do
      Repo.transaction(fn -> demote_in_transaction(actor, target_user_id, force?) end)
    end
  end

  @doc """
  Whether at least one admin other than `target` can currently sign in.

  The last-admin guard in `demote/3` calls it under the admin row lock, so
  concurrent demotions cannot both pass it. The admin UI also calls it,
  unlocked, to decide whether to offer self-demotion; that answer is advisory,
  and `demote/3` decides.
  """
  @spec remaining_signin_capable_admins?(UserSchema.t()) :: boolean()
  def remaining_signin_capable_admins?(%UserSchema{id: target_id}) do
    AdminUserQueries.count_signin_capable_admins_excluding(
      target_id,
      LockoutPolicy.usable_signin_paths()
    ) > 0
  end

  # --- Private helpers ---

  defp demote_in_transaction(actor, target_user_id, force?) do
    # Lock all admin rows before counting so that concurrent demotions
    # see a consistent view and cannot race past the last-admin guard.
    AdminUserQueries.lock_admins()
    authorise!(actor)

    case UserQueries.get_user(target_user_id) do
      {:error, :not_found} ->
        Repo.rollback(:not_found)

      {:ok, target} ->
        apply_demotion(actor, target, force?)
    end
  end

  defp apply_demotion(actor, target, force?) do
    case check_last_admin(target, force?) do
      {:error, :last_admin} ->
        Repo.rollback(:last_admin)

      :ok ->
        case AdminUserQueries.set_admin(target, false) do
          {:ok, updated} ->
            log_role_change(:demote, actor, updated.id)
            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  @doc """
  Whether the admin UI is enabled for this deployment.

  Reflects the `:enable_admin_ui` feature flag (Core defaults to `true`; the
  SaaS overlay sets it to `false` to lock down the self-host admin scope). Use
  this to decide whether admin affordances (menu entries, links) should be
  offered at all, mirroring the `RequireAdminUiEnabled` route guard.
  """
  @spec admin_ui_enabled?() :: boolean()
  def admin_ui_enabled? do
    Application.get_env(:tymeslot, :enable_admin_ui, true)
  end

  defp ensure_admin_ui_enabled do
    if admin_ui_enabled?() do
      :ok
    else
      {:error, :admin_ui_disabled}
    end
  end

  # Runs inside the role-change transaction and rolls it back with
  # `:forbidden` unless the actor may change roles. A user actor's admin flag
  # is re-read rather than trusted from the struct, which may have been loaded
  # before that user was demoted.
  defp authorise!(:cli), do: :ok

  defp authorise!(%UserSchema{is_admin: true, id: actor_id}) do
    case UserQueries.get_user(actor_id) do
      {:ok, %UserSchema{is_admin: true}} -> :ok
      _demoted_or_deleted -> Repo.rollback(:forbidden)
    end
  end

  defp authorise!(_actor), do: Repo.rollback(:forbidden)

  # A forced CLI demotion skips the guard: it is the operator escape hatch.
  defp check_last_admin(_target, true = _force?), do: :ok

  # Target is already not an admin, so there is no risk of stranding the install.
  defp check_last_admin(%UserSchema{is_admin: false}, _force?), do: :ok

  # Counts the admins who could still sign in once the target is demoted,
  # rather than bare `is_admin` rows: an admin who is unverified, or whose only
  # identity is with a disabled SSO provider, cannot reach the admin UI.
  defp check_last_admin(%UserSchema{is_admin: true} = target, _force?) do
    if remaining_signin_capable_admins?(target), do: :ok, else: {:error, :last_admin}
  end

  defp log_role_change(action, :cli, target_user_id) do
    Logger.info("Admin role changed",
      event: "admin_role_change",
      action: action,
      target_user_id: target_user_id,
      actor: "cli"
    )
  end

  defp log_role_change(action, %UserSchema{id: actor_id}, target_user_id) do
    Logger.info("Admin role changed",
      event: "admin_role_change",
      action: action,
      target_user_id: target_user_id,
      actor: actor_id
    )
  end
end
