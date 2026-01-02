defmodule Tymeslot.Auth.Helpers.ErrorFormatting do
  @moduledoc """
  Consistent error message formatting for account operations.

  Provides centralized error formatting functions to ensure consistent
  user-facing error messages across all account modules.
  """

  alias Ecto.Changeset

  @doc """
  Formats validation errors into a readable string.

  ## Parameters
  - `errors`: Map of field errors

  ## Returns
  - Formatted error string

  ## Examples
      iex> format_validation_errors(%{email: ["can't be blank"], password: ["too short"]})
      "email: can't be blank, password: too short"
  """
  @spec format_validation_errors(map()) :: String.t()
  def format_validation_errors(errors) when is_map(errors) do
    Enum.map_join(errors, ", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  @doc """
  Formats Ecto changeset errors into a readable string.

  ## Parameters
  - `changeset`: Ecto changeset with errors

  ## Returns
  - Formatted error string

  ## Examples
      iex> changeset = %Ecto.Changeset{errors: [email: {"has already been taken", []}]}
      iex> format_changeset_errors(changeset)
      "email: has already been taken"
  """
  @spec format_changeset_errors(Ecto.Changeset.t()) :: String.t()
  def format_changeset_errors(%Changeset{} = changeset) do
    formatted =
      Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    Enum.map_join(formatted, ", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  @doc """
  Formats operation-specific errors with user-friendly messages.

  ## Parameters
  - `operation`: The operation that failed (e.g., "registration", "authentication")
  - `reason`: The error reason (string or atom)

  ## Returns
  - User-friendly error message

  ## Examples
      iex> format_user_friendly_error("registration", "email: has already been taken")
      "This email address is already registered. Please use a different email or try logging in."
  """
  @spec format_user_friendly_error(String.t(), String.t() | atom()) :: String.t()
  def format_user_friendly_error(operation, reason) when is_binary(reason) do
    case detect_error_type(reason) do
      :email_taken -> format_email_taken_error(operation)
      :general_taken -> "This information is already in use. Please try with different details."
      :password_too_short -> "Password must be at least 8 characters long."
      :invalid_email -> "Please enter a valid email address."
      :unknown -> "#{String.capitalize(operation)} failed: #{reason}"
    end
  end

  def format_user_friendly_error(operation, reason) do
    "#{String.capitalize(operation)} failed: #{inspect(reason)}"
  end

  # Private helper functions to reduce cyclomatic complexity

  @spec detect_error_type(String.t()) :: atom()
  defp detect_error_type(reason) do
    cond do
      String.contains?(reason, "email: has already been taken") -> :email_taken
      String.contains?(reason, "has already been taken") -> :general_taken
      password_too_short?(reason) -> :password_too_short
      invalid_email?(reason) -> :invalid_email
      true -> :unknown
    end
  end

  @spec format_email_taken_error(String.t()) :: String.t()
  defp format_email_taken_error("registration") do
    "This email address is already registered. Please use a different email or try logging in."
  end

  defp format_email_taken_error(_operation) do
    "This email address is already in use. Please try with a different email."
  end

  @spec password_too_short?(String.t()) :: boolean()
  defp password_too_short?(reason) do
    String.contains?(reason, "password") and String.contains?(reason, "too short")
  end

  @spec invalid_email?(String.t()) :: boolean()
  defp invalid_email?(reason) do
    String.contains?(reason, "email") and String.contains?(reason, "invalid")
  end

  @doc """
  Formats authentication-specific errors with security-conscious messages.

  ## Parameters
  - `reason`: The authentication error reason

  ## Returns
  - Generic security message to prevent information disclosure
  """
  @spec format_auth_error(atom() | String.t()) :: String.t()
  def format_auth_error(:not_found), do: "Invalid email or password."
  def format_auth_error(:invalid_password), do: "Invalid email or password."

  def format_auth_error(:rate_limit_exceeded),
    do: "Too many login attempts. Please try again later."

  def format_auth_error(_), do: "Authentication failed. Please try again."

  @doc """
  Formats verification-specific errors.

  ## Parameters
  - `reason`: The verification error reason

  ## Returns
  - User-friendly verification error message
  """
  @spec format_verification_error(atom() | String.t()) :: String.t()
  def format_verification_error(:invalid_token),
    do: "Invalid verification token. Please request a new verification email."

  def format_verification_error(:token_expired),
    do: "Your verification token has expired. Please request a new verification email."

  def format_verification_error(:rate_limited),
    do: "Too many verification attempts. Please try again later."

  def format_verification_error(:email_send_failed),
    do: "Failed to send verification email. Please try again later."

  def format_verification_error(_), do: "Verification failed. Please try again."

  @doc """
  Formats password reset-specific errors.

  ## Parameters
  - `reason`: The password reset error reason

  ## Returns
  - User-friendly password reset error message
  """
  @spec format_password_reset_error(atom() | String.t()) :: String.t()
  def format_password_reset_error(:user_not_found),
    do: "If your email is registered, you will receive password reset instructions."

  def format_password_reset_error(:oauth_user),
    do:
      "You cannot reset your password because your account is managed by an external authentication provider."

  def format_password_reset_error(:invalid_token), do: "Invalid or expired password reset token."

  def format_password_reset_error(:rate_limited),
    do: "Too many password reset attempts. Please try again later."

  def format_password_reset_error(_), do: "Password reset failed. Please try again."
end
