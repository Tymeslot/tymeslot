defmodule Tymeslot.Release do
  @moduledoc """
  Helpers callable from a packaged release where `mix` is not available.

  Designed to be invoked via `bin/tymeslot rpc` (against a running node) or
  `bin/tymeslot eval` (in a one-shot helper VM). The mix tasks under
  `Mix.Tasks.Tymeslot.*` delegate here so the implementation stays in one
  place and behaves identically across dev (`mix tymeslot.promote_admin`)
  and production (`bin/tymeslot rpc 'Tymeslot.Release.promote_admin("…")'`).
  """

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

  The CLI actor skips the last-admin guard — it is the operator escape hatch
  for recovering a stranded install. Same return shape as `promote_admin/1`.
  """
  @spec demote_admin(String.t()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :admin_ui_disabled | Ecto.Changeset.t()}
  def demote_admin(email) when is_binary(email) do
    ensure_started()

    with {:ok, user} <- UserQueries.get_user_by_email(email) do
      AdminRoles.demote(:cli, user.id)
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
