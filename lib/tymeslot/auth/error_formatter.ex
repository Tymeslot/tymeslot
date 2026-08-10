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
      true -> dgettext("auth", "An error occurred. Please try again.")
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
    dgettext(
      "auth",
      "Your account has been locked due to too many failed attempts. Please try again later."
    )
  end

  defp format_account_status_error(:account_throttled) do
    dgettext("auth", "Too many login attempts. Please wait before trying again.")
  end

  defp format_account_status_error(:email_not_verified) do
    dgettext("auth", "Please verify your email address before logging in.")
  end

  defp format_rate_limit_error do
    dgettext("auth", "Too many attempts. Please try again later.")
  end

  defp format_oauth_error(:oauth_user) do
    dgettext(
      "auth",
      "This email is associated with a social login. Please use your original sign-in method."
    )
  end

  defp format_oauth_error(:user_already_exists) do
    dgettext("auth", "This email is already registered. Please sign in instead.")
  end

  defp format_oauth_error(_reason) do
    dgettext("auth", "Authentication failed. Please try again.")
  end

  defp format_token_error(:token_expired) do
    dgettext("auth", "The link has expired. Please request a new one.")
  end

  defp format_token_error(_reason) do
    dgettext("auth", "The link is invalid or has expired. Please request a new one.")
  end

  defp format_registration_error(:profile_creation) do
    dgettext("auth", "Account created but profile setup failed. Please contact support.")
  end

  defp format_registration_error(:verification) do
    dgettext("auth", "Account created but email verification failed. Please contact support.")
  end

  defp format_registration_error(_reason) do
    dgettext("auth", "Registration failed. Please try again.")
  end

  defp format_password_reset_error do
    dgettext("auth", "Unable to reset password. Please try again.")
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
    changeset
    |> Changeset.traverse_errors(&translate_changeset_error/1)
    |> format_error_map()
  end

  def format_validation_errors(errors) when is_map(errors) do
    format_error_map(errors)
  end

  def format_validation_errors(_input), do: dgettext("auth", "Invalid input provided.")

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
    dgettext("auth", "Invalid email or password.")
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
        dgettext("auth", "This information is already in use. Please try with different details.")

      String.contains?(reason, "password") and String.contains?(reason, "too short") ->
        dgettext("auth", "Password must be at least 8 characters long.")

      String.contains?(reason, "email") and String.contains?(reason, "invalid") ->
        dgettext("auth", "Please enter a valid email address.")

      true ->
        operation_failed(operation, reason)
    end
  end

  def format_user_friendly_error(operation, reason) do
    operation_failed(operation, inspect(reason))
  end

  defp operation_failed(operation, reason) do
    dgettext("auth", "%{operation} failed: %{reason}",
      operation: operation_name(operation),
      reason: reason
    )
  end

  defp operation_name("registration"), do: dgettext("auth", "Registration")
  defp operation_name(operation), do: String.capitalize(operation)

  @doc """
  Formats email verification errors.
  """
  @spec format_verification_error(atom() | String.t()) :: String.t()
  def format_verification_error(:invalid_token),
    do: dgettext("auth", "Invalid verification token. Please request a new verification email.")

  def format_verification_error(:token_expired),
    do:
      dgettext(
        "auth",
        "Your verification token has expired. Please request a new verification email."
      )

  def format_verification_error(:rate_limited),
    do: dgettext("auth", "Too many verification attempts. Please try again later.")

  def format_verification_error(:email_send_failed),
    do: dgettext("auth", "Failed to send verification email. Please try again later.")

  def format_verification_error(_reason),
    do: dgettext("auth", "Verification failed. Please try again.")

  @doc """
  Formats password reset operation errors.
  """
  @spec format_password_reset_error(atom() | String.t()) :: String.t()
  def format_password_reset_error(:user_not_found),
    do:
      dgettext(
        "auth",
        "If your email is registered, you will receive password reset instructions."
      )

  def format_password_reset_error(:oauth_user),
    do:
      dgettext(
        "auth",
        "You cannot reset your password because your account is managed by an external authentication provider."
      )

  def format_password_reset_error(:invalid_token),
    do: dgettext("auth", "Invalid or expired password reset token.")

  def format_password_reset_error(:rate_limited),
    do: dgettext("auth", "Too many password reset attempts. Please try again later.")

  def format_password_reset_error(_reason),
    do: dgettext("auth", "Password reset failed. Please try again.")

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
        dgettext("auth", "%{provider} authorization was denied. Please try again.",
          provider: provider_name
        )

      :invalid_response ->
        dgettext("auth", "Invalid response from %{provider}. Please try again.",
          provider: provider_name
        )

      :token_exchange_failed ->
        dgettext("auth", "Failed to authenticate with %{provider}. Please try again.",
          provider: provider_name
        )

      _error ->
        dgettext("auth", "%{provider} authentication failed. Please try again.",
          provider: provider_name
        )
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
    minutes = if retry_after, do: div(retry_after, 60), else: 0

    cond do
      is_nil(retry_after) ->
        dgettext("auth", "Too many %{operation} attempts. Please try again later.",
          operation: rate_limit_operation(operation)
        )

      minutes > 0 ->
        dgettext(
          "auth",
          "Too many %{operation} attempts. Please try again in %{minutes} minute(s).",
          operation: rate_limit_operation(operation),
          minutes: minutes
        )

      true ->
        dgettext(
          "auth",
          "Too many %{operation} attempts. Please try again in %{seconds} seconds.",
          operation: rate_limit_operation(operation),
          seconds: retry_after
        )
    end
  end

  # The operation is interpolated into a translated sentence, so the few labels
  # the auth flows pass are translated too. Anything else falls through as-is.
  defp rate_limit_operation("login"), do: dgettext("auth", "login")
  defp rate_limit_operation("authentication"), do: dgettext("auth", "authentication")
  defp rate_limit_operation(operation), do: operation

  # Private helpers

  defp format_email_taken_error("registration") do
    dgettext(
      "auth",
      "This email address is already registered. Please use a different email or try logging in."
    )
  end

  defp format_email_taken_error(_operation) do
    dgettext("auth", "This email address is already in use. Please try with a different email.")
  end

  defp format_error_map(errors) when is_map(errors) do
    Enum.map_join(errors, ". ", fn {field, messages} ->
      format_field_error(field, List.wrap(messages))
    end)
  end
end
