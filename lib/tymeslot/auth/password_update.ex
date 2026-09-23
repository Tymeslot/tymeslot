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
  alias Tymeslot.Repo
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

  A failure is `{:error, %{field => message}}`, keyed by the form field each
  message belongs to. Malformed input is reported for every field at once;
  only then is the current password checked, and it is checked first: a wrong
  current password is reported as such even when the new password happens to
  equal what was typed.

  `user` only identifies the account. It is re-read under a row lock before
  anything is checked, so a caller holding a stale copy (a LiveView's
  `current_user`, loaded at mount) neither checks against an old password
  hash nor leaves a token issued since then alive.
  """
  @spec update_user_password(term(), term(), term(), term(), keyword()) ::
          {:ok, term()} | {:error, %{optional(error_field()) => String.t()}}
  def update_user_password(
        user,
        current_password,
        new_password,
        new_password_confirmation,
        opts
      ) do
    with :ok <- validate_input(current_password, new_password, new_password_confirmation),
         {:ok, updated_user} <-
           update_in_transaction(
             user.id,
             current_password,
             new_password,
             new_password_confirmation
           ),
         :ok <- Session.revoke_all_sessions(updated_user.id) do
      SecurityLogger.log_password_change(updated_user.id, %{
        ip_address: opts[:ip_address],
        user_agent: opts[:user_agent],
        sessions_invalidated: true
      })

      {:ok, updated_user}
    else
      {:error, errors} when is_map(errors) and not is_struct(errors) ->
        {:error, errors}

      {:error, reason} when reason in [:invalid_password, :missing_password] ->
        {:error, %{current_password: Validation.current_password_message(reason)}}

      {:error, :not_found} ->
        {:error, %{current_password: Validation.current_password_message(:invalid_password)}}

      {:error, :same_as_old} ->
        {:error,
         %{
           new_password: dgettext("auth", "New password must be different from current password")
         }}

      # The input was validated up front, so what the changeset can still
      # refuse is the password policy itself.
      {:error, %Changeset{} = changeset} ->
        {:error, %{new_password: ChangesetUtils.get_first_error(changeset)}}
    end
  end

  # --- Private helpers ---

  # Every field's problem at once, so the form can show them together. The
  # current password is held only to login's presence and length rules.
  defp validate_input(current_password, new_password, new_password_confirmation) do
    errors =
      Map.merge(
        current_password_errors(current_password),
        new_password_errors(new_password, new_password_confirmation)
      )

    if errors == %{}, do: :ok, else: {:error, errors}
  end

  defp current_password_errors(password) do
    case Validation.validate_current_password_input(password) do
      :ok -> %{}
      {:error, reason} -> %{current_password: Validation.current_password_message(reason)}
    end
  end

  defp new_password_errors(password, password_confirmation) do
    case Validation.validate_new_password_input(%{
           "password" => password,
           "password_confirmation" => password_confirmation
         }) do
      {:ok, _params} ->
        %{}

      {:error, errors} ->
        password_error = errors |> Map.get(:password) |> first_message()
        confirmation_error = errors |> Map.get(:password_confirmation) |> first_message()

        # The confirmation is held to the same policy, so a weak password
        # fails it with the same message; say it once, on the password.
        confirmation_error =
          if confirmation_error == password_error, do: nil, else: confirmation_error

        %{new_password: password_error, new_password_confirmation: confirmation_error}
        |> Enum.reject(fn {_field, message} -> is_nil(message) end)
        |> Map.new()
    end
  end

  defp first_message([message | _rest]), do: message
  defp first_message(message), do: message

  # The row lock serialises this against a concurrent token issue (an email
  # change requested in another session), so the revocation the password
  # write carries cannot miss a token created meanwhile.
  defp update_in_transaction(user_id, current_password, new_password, new_password_confirmation) do
    Repo.transaction(fn ->
      with {:ok, user} <- UserQueries.get_user_for_update(user_id),
           :ok <- Validation.check_current_password(user, current_password),
           :ok <- ensure_not_same_as_old(user, new_password),
           {:ok, updated_user} <-
             UserQueries.update_user_password(user, new_password, new_password_confirmation) do
        updated_user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Only reached once the current password matched, so the account has a hash
  # and `new_password` passed validation as a string.
  defp ensure_not_same_as_old(user, new_password) do
    if Password.verify_password(new_password, user.password_hash),
      do: {:error, :same_as_old},
      else: :ok
  end
end
