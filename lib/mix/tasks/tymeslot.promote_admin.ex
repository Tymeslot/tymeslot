defmodule Mix.Tasks.Tymeslot.PromoteAdmin do
  @moduledoc """
  Promotes an existing user to admin.

  ## Usage

      mix tymeslot.promote_admin user@example.com

  The user must already exist — this task does not create accounts.

  In production (packaged release builds, where `mix` is unavailable) use
  the equivalent release helper:

      bin/tymeslot rpc 'Tymeslot.Release.promote_admin("user@example.com")'

  See `docs/admin-bootstrap.md` for per-deployment-target instructions
  (Docker, Cloudron, Railway, source installs).
  """

  use Mix.Task

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.Release

  @shortdoc "Promote an existing user to admin"

  @impl Mix.Task
  def run([email]) when is_binary(email) do
    Mix.Task.run("app.start")

    already_admin? = match?(%{is_admin: true}, Auth.get_user_by_email(email))

    case Release.promote_admin(email) do
      {:ok, user} when already_admin? ->
        Mix.shell().info("#{user.email} (id: #{user.id}) is already an admin; no change made.")

      {:ok, user} ->
        Mix.shell().info("Promoted #{user.email} (id: #{user.id}) to admin.")

      {:error, :not_found} ->
        Mix.raise("No user found with email #{inspect(email)}.")

      {:error, :admin_ui_disabled} ->
        Mix.raise(
          "Admin UI is disabled in this deployment (enable_admin_ui = false), " <>
            "so there is no admin role for promote_admin to change."
        )

      {:error, %Changeset{} = changeset} ->
        Mix.raise("Failed to promote user: #{inspect(changeset.errors)}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix tymeslot.promote_admin <email>")
  end
end
