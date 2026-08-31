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
  alias Tymeslot.Release

  @shortdoc "Demote an admin back to a regular user"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: [force: :boolean]) do
      {opts, [email], []} -> apply_demotion(email, opts[:force] == true)
      _other -> Mix.raise("Usage: mix tymeslot.demote_admin <email> [--force]")
    end
  end

  # The last-admin guard itself lives in `Tymeslot.Release.demote_admin/2` so
  # this task and the production `bin/tymeslot rpc` path share one
  # implementation rather than carrying two copies that can drift.
  defp apply_demotion(email, force?) do
    case Release.demote_admin(email, force?) do
      {:ok, user} ->
        Mix.shell().info("Demoted #{user.email} (id: #{user.id}) from admin.")

      {:error, :not_found} ->
        Mix.raise("No user found with email #{inspect(email)}.")

      {:error, :admin_ui_disabled} ->
        Mix.raise(
          "Admin UI is disabled in this deployment (enable_admin_ui = false), " <>
            "so there is no admin role for demote_admin to change."
        )

      {:error, :last_admin} ->
        Mix.raise(
          "#{email} is the only remaining admin. Demoting them would leave this install " <>
            "with no administrator. Re-run with --force to proceed anyway."
        )

      {:error, %Changeset{} = changeset} ->
        Mix.raise("Failed to demote user: #{inspect(changeset.errors)}")
    end
  end
end
