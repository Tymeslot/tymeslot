defmodule Tymeslot.Auth.PasswordUpdate do
  @moduledoc """
  Handles password updates for authenticated users.

  Validates the current password, enforces the shared password policy
  (`Tymeslot.Auth.Validation.validate_new_password_input/1`, plus not reusing
  the old password), persists the new hash, revokes any outstanding reset or
  email change token, and invalidates all existing sessions.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset

  alias Tymeslot.Auth.{Session, UserQueries, Validation}
  alias Tymeslot.Security.{Password, SecurityLogger}
  alias Tymeslot.Utils.ChangesetUtils

  @type error_field :: :current_password | :new_password | :new_password_confirmation

  @doc """
  Updates a user's password after verifying their current password.
  Pure domain logic without HTTP concerns.

  `opts` carries the request context for the audit entry the change emits:
  `:ip_address` and `:user_agent`. Both are optional, but an audit entry for a
  password change that names no origin is materially weaker, so callers that
  have them should pass them.

  A failure names the form field it belongs to alongside the translated
  message, so a caller can place the error without reading the message. The
  current password is checked first: a wrong current password is reported as
  such even when the new password happens to equal what was typed.
  """
  @spec update_user_password(term(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, {error_field(), String.t()}}
  def update_user_password(
        user,
        current_password,
        new_password,
        new_password_confirmation,
        opts
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
        {:error, {:current_password, dgettext("auth", "Current password is incorrect")}}

      {:error, :missing_password} ->
        {:error, {:current_password, dgettext("auth", "Password is required")}}

      # `validate_new_password/2` has already ruled out a mismatched or short
      # confirmation, so what the changeset can still refuse is the password
      # policy itself.
      {:error, %Changeset{} = changeset} ->
        {:error, {:new_password, ChangesetUtils.get_first_error(changeset)}}

      {:error, {_field, message}} = error when is_binary(message) ->
        error
    end
  end

  # --- Private helpers ---

  defp verify_current_password(user, password) do
    Validation.check_current_password(user, password)
  end

  # Only reached once the current password matched, so the account has a hash
  # and `new_password` is a string (the same bytes were just verified or not).
  defp ensure_not_same_as_old(user, new_password) do
    if is_binary(new_password) and Password.verify_password(new_password, user.password_hash) do
      {:error,
       {:new_password, dgettext("auth", "New password must be different from current password")}}
    else
      :ok
    end
  end

  defp validate_new_password(password, password_confirmation) do
    case Validation.validate_new_password_input(%{
           "password" => password,
           "password_confirmation" => password_confirmation
         }) do
      {:ok, _params} ->
        :ok

      # A policy failure on the password itself is reported there; the
      # confirmation only carries its own error when the password is fine.
      {:error, %{password: message}} ->
        {:error, {:new_password, first_message(message)}}

      {:error, %{password_confirmation: message}} ->
        {:error, {:new_password_confirmation, first_message(message)}}
    end
  end

  defp first_message([message | _rest]), do: message
  defp first_message(message) when is_binary(message), do: message

  defp do_update_password(user, new_password, new_password_confirmation) do
    UserQueries.update_user_password(user, new_password, new_password_confirmation)
  end
end
