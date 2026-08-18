defmodule Mix.Tasks.Tymeslot.DemoteAdmin do
  @moduledoc """
  Demotes a user from admin back to a regular account.

  ## Usage

      mix tymeslot.demote_admin user@example.com

  In production (packaged release builds) use the equivalent release helper:

      bin/tymeslot rpc 'Tymeslot.Release.demote_admin("user@example.com")'

  See `docs/admin-bootstrap.md` for per-deployment-target instructions.
  """

  use Mix.Task

  alias Ecto.Changeset
  alias Tymeslot.Release

  @shortdoc "Demote an admin back to a regular user"

  @impl Mix.Task
  def run([email]) when is_binary(email) do
    Mix.Task.run("app.start")

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

  def run(_args) do
    Mix.raise("Usage: mix tymeslot.demote_admin <email>")
  end
end
