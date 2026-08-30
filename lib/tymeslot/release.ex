defmodule Tymeslot.Release do
  @moduledoc """
  Helpers callable from a packaged release where `mix` is not available.

  Designed to be invoked via `bin/tymeslot rpc` (against a running node) or
  `bin/tymeslot eval` (in a one-shot helper VM). The mix tasks under
  `Mix.Tasks.Tymeslot.*` delegate here so the implementation stays in one
  place and behaves identically across dev (`mix tymeslot.promote_admin`)
  and production (`bin/tymeslot rpc 'Tymeslot.Release.promote_admin("…")'`).
  """

  alias Tymeslot.AppSettings
  alias Tymeslot.AppSettings.LockoutPolicy
  alias Tymeslot.Auth
  alias Tymeslot.Auth.{AdminRoles, UserQueries, UserSchema}

  @doc """
  Promotes the user with the given email to admin.

  Returns:
    * `{:ok, %UserSchema{}}` on success (or if already admin)
    * `{:error, :not_found}` if no user has that email
    * `{:error, :admin_ui_disabled}` if the admin UI is disabled (SaaS)
    * `{:error, changeset}` if the update itself fails
  """
  @spec promote_admin(String.t()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :admin_ui_disabled | Ecto.Changeset.t()}
  def promote_admin(email) when is_binary(email) do
    ensure_started()

    with {:ok, user} <- UserQueries.get_user_by_email(email) do
      AdminRoles.promote(:cli, user.id)
    end
  end

  @doc """
  Demotes the user with the given email from admin.

  Refuses to demote the only remaining admin unless `force?` is true. This
  mirrors the pre-check `mix tymeslot.demote_admin` applies before reaching
  this function, so the documented production path
  (`bin/tymeslot rpc 'Tymeslot.Release.demote_admin("…")'`) gets the same
  protection rather than relying solely on the dev-only Mix task. Below this
  guard, the `:cli` actor still skips `AdminRoles.demote/2`'s own last-admin
  check by design — that remains the operator escape hatch for recovering an
  already-stranded install; `force?` is this function's equivalent for
  callers going through it directly.
  """
  @spec demote_admin(String.t(), boolean()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :admin_ui_disabled | :last_admin | Ecto.Changeset.t()}
  def demote_admin(email, force? \\ false) when is_binary(email) do
    ensure_started()

    with :ok <- ensure_admin_ui_enabled(),
         {:ok, user} <- UserQueries.get_user_by_email(email),
         :ok <- check_last_admin(user, force?) do
      AdminRoles.demote(:cli, user.id)
    end
  end

  # Checked here too (rather than relying solely on `AdminRoles.demote/2`'s
  # own check) so it runs before the last-admin guard below, keeping the
  # error precedence promote_admin/1 and the pre-fix demote_admin/1 already
  # had: a disabled admin UI is reported as such even for a sole admin.
  defp ensure_admin_ui_enabled do
    if AdminRoles.admin_ui_enabled?(), do: :ok, else: {:error, :admin_ui_disabled}
  end

  defp check_last_admin(%UserSchema{id: id, is_admin: true}, false) do
    if Auth.count_signin_capable_admins_excluding(id, usable_sso_providers()) > 0 do
      :ok
    else
      {:error, :last_admin}
    end
  end

  defp check_last_admin(_user, _force?), do: :ok

  # Which SSO identities count as a live sign-in path right now: enabled
  # system-wide AND with credentials configured, mirroring
  # `LockoutPolicy`'s definition of a usable auth path. Passed as data into
  # `count_signin_capable_admins_excluding/2` rather than letting the query
  # module read config itself.
  @sso_settings %{
    google: :google_auth_enabled,
    github: :github_auth_enabled,
    oauth: :oauth_auth_enabled
  }

  defp usable_sso_providers do
    for {kind, key} <- @sso_settings,
        AppSettings.get(key) == true,
        LockoutPolicy.sso_credentials_present?(key) do
      kind
    end
  end

  @doc """
  Lists every admin user (email + id). Useful for operators verifying the
  current state of an install.
  """
  @spec list_admins() :: [%{id: integer(), email: String.t()}]
  def list_admins do
    ensure_started()

    Enum.map(UserQueries.list_admins(), fn user -> %{id: user.id, email: user.email} end)
  end

  # When called via `bin/tymeslot eval`, the application isn't started — we
  # need at least the Repo running to issue queries. `rpc` against a live
  # node already has everything up, so the second start is a no-op.
  defp ensure_started do
    {:ok, _apps} = Application.ensure_all_started(:tymeslot)
    :ok
  end
end
