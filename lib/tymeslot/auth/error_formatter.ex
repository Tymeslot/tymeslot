defmodule Tymeslot.Auth.ErrorFormatter do
  @moduledoc """
  Unified error formatting for the authentication system.

  This module provides consistent error messages across all authentication
  operations, preventing information leakage and improving user experience.
  """

  alias Ecto.Changeset

  @doc """
  Formats authentication errors with consistent messaging.

  ## Parameters
  - reason: The error reason atom or string

  ## Returns
  - A user-friendly error message string
  """
  @spec format_auth_error(atom() | String.t()) :: String.t()
  def format_auth_error(reason) when is_binary(reason), do: reason

  def format_auth_error(reason) do
    cond do
      auth_error?(reason) -> generic_auth_error()
      account_status_error?(reason) -> format_account_status_error(reason)
      rate_limit_error?(reason) -> format_rate_limit_error()
      oauth_error?(reason) -> format_oauth_error(reason)
      token_error?(reason) -> format_token_error(reason)
      registration_error?(reason) -> format_registration_error(reason)
      password_reset_error?(reason) -> format_password_reset_error()
      true -> "An error occurred. Please try again."
    end
  end

  defp auth_error?(reason) do
    reason in [:invalid_input, :not_found, :invalid_password, :invalid_credentials]
  end

  defp account_status_error?(reason) do
    reason in [:account_locked, :account_throttled, :email_not_verified]
  end

  defp rate_limit_error?(reason) do
    reason in [:rate_limited, :rate_limit_exceeded]
  end

  defp oauth_error?(reason) do
    reason in [
      :oauth_user,
      :user_already_exists,
      :invalid_oauth_state,
      :oauth_state_expired,
      :missing_oauth_state
    ]
  end

  defp token_error?(reason) do
    reason in [:invalid_token, :token_expired, :token_invalid]
  end

  defp registration_error?(reason) do
    reason in [:registration_failed, :profile_creation, :verification]
  end

  defp password_reset_error?(reason) do
    reason == :password_reset_failed
  end

  defp format_account_status_error(:account_locked) do
    "Your account has been locked due to too many failed attempts. Please try again later."
  end

  defp format_account_status_error(:account_throttled) do
    "Too many login attempts. Please wait before trying again."
  end

  defp format_account_status_error(:email_not_verified) do
    "Please verify your email address before logging in."
  end

  defp format_rate_limit_error do
    "Too many attempts. Please try again later."
  end

  defp format_oauth_error(:oauth_user) do
    "This email is associated with a social login. Please use your original sign-in method."
  end

  defp format_oauth_error(:user_already_exists) do
    "This email is already registered. Please sign in instead."
  end

  defp format_oauth_error(_reason) do
    "Authentication failed. Please try again."
  end

  defp format_token_error(:token_expired) do
    "The link has expired. Please request a new one."
  end

  defp format_token_error(_reason) do
    "The link is invalid or has expired. Please request a new one."
  end

  defp format_registration_error(:profile_creation) do
    "Account created but profile setup failed. Please contact support."
  end

  defp format_registration_error(:verification) do
    "Account created but email verification failed. Please contact support."
  end

  defp format_registration_error(_reason) do
    "Registration failed. Please try again."
  end

  defp format_password_reset_error do
    "Unable to reset password. Please try again."
  end

  @doc """
  Formats validation errors from changesets or error maps.

  ## Parameters
  - errors: Ecto.Changeset or map of field errors

  ## Returns
  - A formatted string of all validation errors
  """
  @spec format_validation_errors(Changeset.t() | map()) :: String.t()
  def format_validation_errors(%Changeset{} = changeset) do
    errors =
      Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    format_error_map(errors)
  end

  def format_validation_errors(errors) when is_map(errors) do
    format_error_map(errors)
  end

  def format_validation_errors(_input), do: "Invalid input provided."

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

  @doc """
  Formats a single field error.

  ## Parameters
  - field: The field name atom
  - errors: List of error messages for the field

  ## Returns
  - A formatted string for the field errors
  """
  @spec format_field_error(atom(), list(String.t())) :: String.t()
  def format_field_error(field, errors) when is_list(errors) do
    field_name = field |> to_string() |> String.replace("_", " ") |> String.capitalize()
    "#{field_name} #{Enum.join(errors, ", ")}"
  end

  @doc """
  Returns a generic authentication error message to prevent user enumeration.
  """
  @spec generic_auth_error() :: String.t()
  def generic_auth_error do
    "Invalid email or password."
  end

  @doc """
  Formats registration/operation errors with user-friendly messages.
  """
  @spec format_user_friendly_error(String.t(), String.t() | atom()) :: String.t()
  def format_user_friendly_error(operation, reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "email: has already been taken") ->
        format_email_taken_error(operation)

      String.contains?(reason, "has already been taken") ->
        "This information is already in use. Please try with different details."

      String.contains?(reason, "password") and String.contains?(reason, "too short") ->
        "Password must be at least 8 characters long."

      String.contains?(reason, "email") and String.contains?(reason, "invalid") ->
        "Please enter a valid email address."

      true ->
        "#{String.capitalize(operation)} failed: #{reason}"
    end
  end

  def format_user_friendly_error(operation, reason) do
    "#{String.capitalize(operation)} failed: #{inspect(reason)}"
  end

  @doc """
  Formats email verification errors.
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

  def format_verification_error(_reason), do: "Verification failed. Please try again."

  @doc """
  Formats password reset operation errors.
  """
  @spec format_password_reset_error(atom() | String.t()) :: String.t()
  def format_password_reset_error(:user_not_found),
    do: "If your email is registered, you will receive password reset instructions."

  def format_password_reset_error(:oauth_user),
    do:
      "You cannot reset your password because your account is managed by an external authentication provider."

  def format_password_reset_error(:invalid_token),
    do: "Invalid or expired password reset token."

  def format_password_reset_error(:rate_limited),
    do: "Too many password reset attempts. Please try again later."

  def format_password_reset_error(_reason), do: "Password reset failed. Please try again."

  @doc """
  Formats OAuth-specific errors.

  ## Parameters
  - provider: The OAuth provider atom (:github, :google, etc.)
  - error: The error type

  ## Returns
  - A user-friendly error message
  """
  @spec format_oauth_error(atom(), atom() | String.t()) :: String.t()
  def format_oauth_error(provider, error) do
    provider_name = provider |> to_string() |> String.capitalize()

    case error do
      "access_denied" ->
        "#{provider_name} authorization was denied. Please try again."

      :invalid_response ->
        "Invalid response from #{provider_name}. Please try again."

      :token_exchange_failed ->
        "Failed to authenticate with #{provider_name}. Please try again."

      _error ->
        "#{provider_name} authentication failed. Please try again."
    end
  end

  @doc """
  Formats rate limit errors with appropriate context.

  ## Parameters
  - operation: The operation that was rate limited
  - retry_after: Optional seconds until retry is allowed

  ## Returns
  - A user-friendly rate limit message
  """
  @spec format_rate_limit_error(String.t(), integer() | nil) :: String.t()
  def format_rate_limit_error(operation, retry_after \\ nil) do
    base_message = "Too many #{operation} attempts."

    if retry_after do
      minutes = div(retry_after, 60)

      if minutes > 0 do
        "#{base_message} Please try again in #{minutes} minute(s)."
      else
        "#{base_message} Please try again in #{retry_after} seconds."
      end
    else
      "#{base_message} Please try again later."
    end
  end

  # Private helpers

  defp format_email_taken_error("registration") do
    "This email address is already registered. Please use a different email or try logging in."
  end

  defp format_email_taken_error(_operation) do
    "This email address is already in use. Please try with a different email."
  end

  defp format_error_map(errors) when is_map(errors) do
    Enum.map_join(errors, ". ", fn {field, messages} ->
      format_field_error(field, List.wrap(messages))
    end)
  end
end
