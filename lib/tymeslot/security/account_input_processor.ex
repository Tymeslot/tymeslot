defmodule Tymeslot.Security.AccountInputProcessor do
  @moduledoc """
  Account security input validation and sanitization.

  Provides specialized validation for account security forms including
  email changes and password updates with enhanced security logging.
  """

  alias Tymeslot.Security.FieldValidators.{EmailValidator, PasswordValidator}
  alias Tymeslot.Security.{InputProcessor, SecurityLogger}

  @doc """
  Validates email change form input with security requirements.

  ## Parameters
  - `params` - Email change form parameters (new_email, current_password)
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_email_change(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_email_change(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case InputProcessor.validate_form(
           params,
           [
             {"new_email", EmailValidator},
             {"current_password", PasswordValidator}
           ],
           metadata: metadata,
           universal_opts: [allow_html: false]
         ) do
      {:ok, sanitized_params} ->
        SecurityLogger.log_security_event("account_email_change_validation_success", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id]
        })

        {:ok, sanitized_params}

      {:error, errors} ->
        SecurityLogger.log_security_event("account_email_change_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  @doc """
  Validates password change form input with security requirements.

  ## Parameters
  - `params` - Password change form parameters (current_password, new_password, new_password_confirmation)
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_password_change(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_password_change(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    # First validate individual password fields
    with {:ok, sanitized_params} <-
           InputProcessor.validate_form(
             params,
             [
               {"current_password", PasswordValidator},
               {"new_password", PasswordValidator},
               {"new_password_confirmation", PasswordValidator}
             ],
             metadata: metadata,
             universal_opts: [allow_html: false]
           ),
         :ok <-
           PasswordValidator.validate_confirmation(
             sanitized_params["new_password"],
             sanitized_params["new_password_confirmation"]
           ),
         :ok <- validate_password_not_same(sanitized_params) do
      SecurityLogger.log_security_event("account_password_change_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent],
        user_id: metadata[:user_id]
      })

      {:ok, sanitized_params}
    else
      {:error, errors} when is_map(errors) ->
        SecurityLogger.log_security_event("account_password_change_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors)
        })

        {:error, errors}

      {:error, confirmation_error} when is_binary(confirmation_error) ->
        errors = %{new_password_confirmation: confirmation_error}

        SecurityLogger.log_security_event("account_password_change_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors)
        })

        {:error, errors}

      {:error, :same_password} ->
        errors = %{new_password: "New password must be different from current password"}

        SecurityLogger.log_security_event("account_password_change_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          user_id: metadata[:user_id],
          errors: Map.keys(errors),
          reason: "same_password_attempt"
        })

        {:error, errors}
    end
  end

  @doc """
  Validates account form input for real-time validation (on change events).

  ## Parameters
  - `form_type` - `:email_change` | `:password_change`
  - `params` - Form parameters
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_account_form(atom(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_account_form(:email_change, params, opts) do
    validate_email_change(params, opts)
  end

  def validate_account_form(:password_change, params, opts) do
    validate_password_change(params, opts)
  end

  # Private helper functions

  defp validate_password_not_same(params) do
    current_password = Map.get(params, "current_password", "")
    new_password = Map.get(params, "new_password", "")

    # Note: This is a basic check. In practice, you'd want to hash both
    # and compare, but since we don't have the current password hash here,
    # we just do a basic string comparison for obvious cases.
    if current_password == new_password and current_password != "" do
      {:error, :same_password}
    else
      :ok
    end
  end
end
