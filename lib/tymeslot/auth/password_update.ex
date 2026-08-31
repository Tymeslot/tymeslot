defmodule Tymeslot.Auth.PasswordUpdate do
  @moduledoc """
  Handles password updates for authenticated users.

  Validates the current password, enforces password policies (minimum length,
  confirmation match, not reusing the old password), persists the new hash,
  and invalidates all existing sessions.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset

  alias Tymeslot.Auth.{Session, UserQueries}
  alias Tymeslot.Security.{Password, SecurityLogger}
  alias Tymeslot.Utils.ChangesetUtils

  @doc """
  Updates a user's password after verifying their current password.
  Pure domain logic without HTTP concerns.

  `opts` carries the request context for the audit entry the change emits:
  `:ip_address` and `:user_agent`. Both are optional, but an audit entry for a
  password change that names no origin is materially weaker, so callers that
  have them should pass them.
  """
  @spec update_user_password(term(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, String.t()}
  def update_user_password(
        user,
        current_password,
        new_password,
        new_password_confirmation,
        opts \\ []
      ) do
    with :ok <- verify_current_password(user, current_password),
         :ok <- ensure_not_same_as_old(user, new_password),
         :ok <- validate_new_password(new_password, new_password_confirmation),
         {:ok, updated_user} <- do_update_password(user, new_password, new_password_confirmation),
         :ok <- Session.revoke_all_sessions(user.id) do
      SecurityLogger.log_password_change(user.id, %{
        ip_address: opts[:ip_address],
        user_agent: opts[:user_agent],
        sessions_invalidated: true
      })

      {:ok, updated_user}
    else
      {:error, :invalid_password} ->
        {:error, dgettext("auth", "Current password is incorrect")}

      {:error, %Changeset{} = changeset} ->
        {:error, format_changeset_error(changeset)}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  # --- Private helpers ---

  defp verify_current_password(user, password) do
    if Password.verify_password(password, user.password_hash) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  defp ensure_not_same_as_old(user, new_password) do
    if Password.verify_password(new_password, user.password_hash) do
      {:error, dgettext("auth", "New password must be different from current password")}
    else
      :ok
    end
  end

  defp validate_new_password(password, password_confirmation) do
    cond do
      password != password_confirmation ->
        {:error, dgettext("auth", "Passwords do not match")}

      String.length(password) < 8 ->
        {:error, dgettext("auth", "Password must be at least 8 characters long")}

      true ->
        :ok
    end
  end

  defp do_update_password(user, new_password, new_password_confirmation) do
    UserQueries.update_user_password(user, new_password, new_password_confirmation)
  end

  defp format_changeset_error(%Changeset{} = changeset) do
    ChangesetUtils.get_first_error(changeset)
  end
end
