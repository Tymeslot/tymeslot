defmodule Tymeslot.Auth.ErrorFormatter do
  @moduledoc """
  Unified error formatting for the authentication system.

  This module provides consistent error messages across all authentication
  operations, preventing information leakage and improving user experience.

  Every message it returns is user-facing, so it is translated in the `auth`
  domain. Changeset messages are translated in the `errors` domain, matching
  what `CoreComponents.Forms.translate_error/1` does for inline form errors.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Ecto.Changeset

  @doc """
  The message shown for a failed sign-in, sign-up or password-flow policy
  check, by reason.

  Every reason that means "these credentials did not get you in" (an unknown
  address, a wrong password) shares one message, so the reply never tells a
  visitor which it was. A reason with no clause of its own is a bug below,
  answered with a generic message rather than a crash.
  """
  @spec format_auth_error(atom()) :: String.t()
  def format_auth_error(reason) when reason in [:not_found, :invalid_password],
    do: generic_auth_error()

  def format_auth_error(:oauth_user) do
    dgettext(
      "auth",
      "This email is associated with a social login. Please use your original sign-in method."
    )
  end

  def format_auth_error(:rate_limited), do: too_many_attempts()

  def format_auth_error(:registration_disabled),
    do: dgettext("auth", "Registration is currently disabled.")

  def format_auth_error(:password_auth_disabled),
    do: dgettext("auth", "Password authentication is currently disabled.")

  def format_auth_error(_reason), do: dgettext("auth", "An error occurred. Please try again.")

  @doc """
  The message shown when a password reset (the request, or setting the new
  password) fails, by reason.

  A rejected new password is not handled here: its message names the rule
  it broke and is shown as the domain wrote it. Every other reason describes
  the token or the requester. A reason with no clause is a bug below; it is
  logged and answered with the generic server error, never a crash, since
  the reset pages are public.
  """
  @spec format_password_reset_error(atom()) :: String.t()
  def format_password_reset_error(:rate_limited), do: too_many_attempts()

  def format_password_reset_error(:invalid_token),
    do: dgettext("auth", "Invalid or expired token")

  def format_password_reset_error(:token_expired),
    do: dgettext("auth", "This link has expired. Please request a new one")

  def format_password_reset_error(:invalid_password), do: dgettext("auth", "Invalid password")

  def format_password_reset_error(other) do
    Logger.error("Unmapped auth error reason",
      reason: inspect(other),
      event: :auth_error_unmapped
    )

    server_error()
  end

  defp too_many_attempts, do: dgettext("auth", "Too many attempts. Please try again later.")

  defp server_error, do: dgettext("auth", "A server error occurred. Please try again")

  @doc """
  Formats validation errors from changesets or error maps.

  ## Parameters
  - errors: Ecto.Changeset or map of field errors

  ## Returns
  - A formatted string of all validation errors
  """
  @spec format_validation_errors(Changeset.t() | map()) :: String.t()
  def format_validation_errors(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(&translate_changeset_error/1)
    |> format_error_map()
  end

  def format_validation_errors(errors) when is_map(errors) do
    format_error_map(errors)
  end

  # Mirrors `CoreComponents.Forms.translate_error/1`: the message is a runtime
  # variable, so the msgids live in `TymeslotWeb.Gettext.EctoErrorMsgids` for
  # the extractor to find.
  defp translate_changeset_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(TymeslotWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(TymeslotWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Formats changeset errors into a user-friendly string.

  ## Parameters
  - changeset: An Ecto.Changeset with errors

  ## Returns
  - A formatted string of all errors
  """
  @spec format_changeset_errors(Changeset.t()) :: String.t()
  def format_changeset_errors(changeset) do
    format_validation_errors(changeset)
  end

  # Formats a single field error: the field name, humanised, followed by its
  # error messages.
  @spec format_field_error(atom(), list(String.t())) :: String.t()
  defp format_field_error(field, errors) when is_list(errors) do
    field_name = field |> to_string() |> String.replace("_", " ") |> String.capitalize()
    "#{field_name} #{Enum.join(errors, ", ")}"
  end

  # Returns a generic authentication error message to prevent user enumeration.
  @spec generic_auth_error() :: String.t()
  defp generic_auth_error do
    dgettext(
      "auth",
      "Invalid email or password. If you signed up recently, check your inbox for the verification link."
    )
  end

  @doc """
  Formats a registration failure, given the formatted changeset errors, as a
  user-friendly message.

  A taken address never reaches this: registration answers it as a success,
  so nothing here may say an address is registered.
  """
  @spec format_user_friendly_error(String.t(), String.t()) :: String.t()
  def format_user_friendly_error("registration" = operation, reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "has already been taken") ->
        dgettext("auth", "This information is already in use. Please try with different details.")

      String.contains?(reason, "password") and String.contains?(reason, "too short") ->
        dgettext("auth", "Password must be at least 8 characters long.")

      String.contains?(reason, "email") and String.contains?(reason, "invalid") ->
        dgettext("auth", "Please enter a valid email address.")

      true ->
        operation_failed(operation, reason)
    end
  end

  defp operation_failed(operation, reason) do
    dgettext("auth", "%{operation} failed: %{reason}",
      operation: operation_name(operation),
      reason: reason
    )
  end

  defp operation_name("registration"), do: dgettext("auth", "Registration")

  @doc """
  The message for an operation refused by a rate limit, naming the operation.
  """
  @spec format_rate_limit_error(String.t()) :: String.t()
  def format_rate_limit_error(operation) do
    dgettext("auth", "Too many %{operation} attempts. Please try again later.",
      operation: rate_limit_operation(operation)
    )
  end

  # The operation is interpolated into a translated sentence, so the labels
  # the auth flows pass are translated too. Anything else falls through as-is.
  defp rate_limit_operation("authentication"), do: dgettext("auth", "authentication")
  defp rate_limit_operation(operation), do: operation

  defp format_error_map(errors) when is_map(errors) do
    Enum.map_join(errors, ". ", fn {field, messages} ->
      format_field_error(field, List.wrap(messages))
    end)
  end
end
