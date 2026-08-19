defmodule Mix.Tasks.Tymeslot.DemoteAdmin do
  @moduledoc """
  Demotes a user from admin back to a regular account.

  ## Usage

      mix tymeslot.demote_admin user@example.com

  Refuses to demote the only remaining admin, since that would leave the
  install with no administrator able to reach the admin UI. Pass `--force`
  to demote them anyway (e.g. to remove a compromised account before
  promoting a replacement with `mix tymeslot.promote_admin`).

  In production (packaged release builds) use the equivalent release helper:

      bin/tymeslot rpc 'Tymeslot.Release.demote_admin("user@example.com")'

  See `docs/admin-bootstrap.md` for per-deployment-target instructions.
  """

  use Mix.Task

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.Release

  @shortdoc "Demote an admin back to a regular user"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: [force: :boolean]) do
      {opts, [email], []} -> demote(email, opts[:force] == true)
      _other -> Mix.raise("Usage: mix tymeslot.demote_admin <email> [--force]")
    end
  end

  defp demote(email, force?) do
    if not force? and last_admin?(email) do
      Mix.raise(
        "#{email} is the only remaining admin. Demoting them would leave this install " <>
          "with no administrator. Re-run with --force to proceed anyway."
      )
    else
      apply_demotion(email)
    end
  end

  defp apply_demotion(email) do
    case Release.demote_admin(email) do
      {:ok, user} ->
        Mix.shell().info("Demoted #{user.email} (id: #{user.id}) from admin.")

      {:error, :not_found} ->
        Mix.raise("No user found with email #{inspect(email)}.")

      {:error, :admin_ui_disabled} ->
        Mix.raise(
          "Admin UI is disabled in this deployment (enable_admin_ui = false), " <>
            "so there is no admin role for demote_admin to change."
        )

      {:error, %Changeset{} = changeset} ->
        Mix.raise("Failed to demote user: #{inspect(changeset.errors)}")
    end
  end

  # Best-effort pre-check so the mix task itself refuses to strand the
  # install: `Tymeslot.Auth.AdminRoles.demote/2` skips the last-admin guard
  # for the `:cli` actor by design (it is the operator's escape hatch when
  # the UI is unreachable), so nothing downstream of `Release.demote_admin/1`
  # would otherwise stop this.
  defp last_admin?(email) do
    case Auth.get_user_by_email(email) do
      %{is_admin: true} -> Auth.count_admins() <= 1
      _other -> false
    end
  end
end
