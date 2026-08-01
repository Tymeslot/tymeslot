defmodule Tymeslot.Auth.AdminRoles do
  @moduledoc """
  Domain logic for the admin role lifecycle.

  This module is the single entry point for promoting and demoting admin users.
  Both the LiveView admin UI and the CLI release helpers route through here,
  ensuring that all business rules (last-admin guard, audit logging) are
  applied consistently.

  Self-demotion is allowed for `%UserSchema{}` actors as long as at least one
  other admin remains; the `:last_admin` guard is what prevents stranding the
  install. The `:cli` actor additionally skips the last-admin guard, providing
  an operator escape hatch when the UI cannot be used (e.g. to recover a
  stranded install where every admin has been demoted).
  """

  require Logger

  alias Tymeslot.Auth.{UserQueries, UserSchema}
  alias Tymeslot.Repo

  @type actor :: %UserSchema{} | :cli

  @doc """
  Promotes the user identified by `target_user_id` to admin.

  Idempotent: if the user is already an admin, returns `{:ok, user}` without
  writing to the database.

  Returns:
    * `{:ok, %UserSchema{}}` on success (or if already admin)
    * `{:error, :admin_ui_disabled}` if the admin UI feature flag is off
    * `{:error, :not_found}` if no user has that ID
    * `{:error, changeset}` if the database update fails
  """
  @spec promote(actor(), pos_integer()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :admin_ui_disabled | Ecto.Changeset.t()}
  def promote(actor, target_user_id) do
    with :ok <- ensure_admin_ui_enabled() do
      Repo.transaction(fn ->
        case UserQueries.get_user(target_user_id) do
          {:error, :not_found} ->
            Repo.rollback(:not_found)

          {:ok, %UserSchema{is_admin: true} = target} ->
            target

          {:ok, target} ->
            case UserQueries.set_admin(target, true) do
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
  one other admin will remain afterwards. The `:last_admin` guard below
  prevents stranding the install.

  Guard (skipped when actor is `:cli`):
    * Returns `{:error, :last_admin}` when the target is the only remaining
      admin user (checked inside a locked transaction to prevent races).

  Returns:
    * `{:ok, %UserSchema{}}` on success
    * `{:error, :admin_ui_disabled}` if the admin UI feature flag is off
    * `{:error, :not_found}` if no user has that ID
    * `{:error, :last_admin}` if the target is the only admin
    * `{:error, changeset}` if the database update fails
  """
  @spec demote(actor(), pos_integer()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :last_admin | :admin_ui_disabled | Ecto.Changeset.t()}
  def demote(actor, target_user_id) do
    with :ok <- ensure_admin_ui_enabled() do
      Repo.transaction(fn -> demote_in_transaction(actor, target_user_id) end)
    end
  end

  # --- Private helpers ---

  defp demote_in_transaction(actor, target_user_id) do
    # Lock all admin rows before counting so that concurrent demotions
    # see a consistent view and cannot race past the last-admin guard.
    UserQueries.lock_admins()

    case UserQueries.get_user(target_user_id) do
      {:error, :not_found} ->
        Repo.rollback(:not_found)

      {:ok, target} ->
        apply_demotion(actor, target)
    end
  end

  defp apply_demotion(actor, target) do
    case check_last_admin(actor, target) do
      {:error, :last_admin} ->
        Repo.rollback(:last_admin)

      :ok ->
        case UserQueries.set_admin(target, false) do
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

  # CLI actor: skips the last-admin guard — it is the operator escape hatch.
  defp check_last_admin(:cli, _target), do: :ok

  # Target is already not an admin — no risk of stranding the install.
  defp check_last_admin(_actor, %UserSchema{is_admin: false}), do: :ok

  defp check_last_admin(_actor, %UserSchema{is_admin: true}) do
    if UserQueries.count_admins() <= 1 do
      {:error, :last_admin}
    else
      :ok
    end
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
