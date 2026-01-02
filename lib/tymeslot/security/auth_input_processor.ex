defmodule Tymeslot.Security.AuthInputProcessor do
  @moduledoc """
  Authentication-specific input validation and sanitization.

  Provides specialized validation for authentication forms with
  enhanced security logging and rate limiting integration.
  """

  alias Tymeslot.Security.FieldValidators.{EmailValidator, FullNameValidator, PasswordValidator}
  alias Tymeslot.Security.{InputProcessor, SecurityLogger}
  alias Tymeslot.Deployment

  @doc """
  Validates login form input with authentication-specific rules.

  ## Parameters
  - `params` - Login form parameters (email, password)
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_login_input(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_login_input(params, _opts \\ []) do
    # For login, we only validate email format and password presence (not complexity)
    # Password complexity validation only happens during registration
    email = params["email"]
    password = params["password"]

    errors = %{}

    # Validate email format
    errors =
      case EmailValidator.validate(email) do
        :ok -> errors
        {:error, msg} -> Map.put(errors, :email, msg)
      end

    # Validate password presence only
    errors =
      if is_nil(password) or password == "" do
        Map.put(errors, :password, "Password is required")
      else
        errors
      end

    if map_size(errors) == 0 do
      {:ok, %{params | "email" => email, "password" => password}}
    else
      {:error, errors}
    end
  end

  @doc """
  Validates signup form input with authentication-specific rules.

  ## Parameters
  - `params` - Signup form parameters (email, password, full_name, terms_accepted)
  - `opts` - Options including metadata for logging

  ## Returns
  - `{:ok, sanitized_params}` | `{:error, validation_errors}`
  """
  @spec validate_signup_input(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_signup_input(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    # First validate core fields
    case InputProcessor.validate_form(
           params,
           [
             {"email", EmailValidator},
             {"password", PasswordValidator},
             {"full_name", FullNameValidator}
           ],
           metadata: metadata,
           universal_opts: [allow_html: false]
         ) do
      {:ok, sanitized_params} ->
        # Then validate terms acceptance (only if main deployment)
        if Deployment.main?() do
          case validate_terms_accepted(params) do
            :ok ->
              SecurityLogger.log_security_event("signup_validation_success", %{
                ip_address: metadata[:ip],
                user_agent: metadata[:user_agent]
              })

              {:ok, sanitized_params}

            {:error, terms_error} ->
              errors = %{terms_accepted: terms_error}

              SecurityLogger.log_security_event("signup_validation_failure", %{
                ip_address: metadata[:ip],
                user_agent: metadata[:user_agent],
                errors: Map.keys(errors)
              })

              {:error, errors}
          end
        else
          SecurityLogger.log_security_event("signup_validation_success", %{
            ip_address: metadata[:ip],
            user_agent: metadata[:user_agent]
          })

          {:ok, sanitized_params}
        end

      {:error, errors} ->
        SecurityLogger.log_security_event("signup_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  @doc """
  Validates password reset request input.

  ## Parameters
  - `params` - Password reset form parameters (email)
  - `opts` - Options including metadata for logging
  """
  @spec validate_password_reset_request(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_password_reset_request(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    case InputProcessor.validate_form(
           params,
           [
             {"email", EmailValidator}
           ],
           metadata: metadata,
           universal_opts: [allow_html: false]
         ) do
      {:ok, sanitized_params} ->
        SecurityLogger.log_security_event("password_reset_request_validation_success", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent]
        })

        {:ok, sanitized_params}

      {:error, errors} ->
        SecurityLogger.log_security_event("password_reset_request_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  @doc """
  Validates password reset form input (new password + confirmation).

  ## Parameters
  - `params` - Password reset form parameters (password, password_confirmation)
  - `opts` - Options including metadata for logging
  """
  @spec validate_password_reset_form(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_password_reset_form(params, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    # Validate both password fields separately
    with {:ok, sanitized_params} <-
           InputProcessor.validate_form(
             params,
             [
               {"password", PasswordValidator},
               {"password_confirmation", PasswordValidator}
             ],
             metadata: metadata,
             universal_opts: [allow_html: false]
           ),
         :ok <-
           PasswordValidator.validate_confirmation(
             sanitized_params["password"],
             sanitized_params["password_confirmation"]
           ) do
      SecurityLogger.log_security_event("password_reset_form_validation_success", %{
        ip_address: metadata[:ip],
        user_agent: metadata[:user_agent]
      })

      {:ok, sanitized_params}
    else
      {:error, errors} when is_map(errors) ->
        SecurityLogger.log_security_event("password_reset_form_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          errors: Map.keys(errors)
        })

        {:error, errors}

      {:error, confirmation_error} ->
        errors = %{password_confirmation: confirmation_error}

        SecurityLogger.log_security_event("password_reset_form_validation_failure", %{
          ip_address: metadata[:ip],
          user_agent: metadata[:user_agent],
          errors: Map.keys(errors)
        })

        {:error, errors}
    end
  end

  # Private helper functions

  defp validate_terms_accepted(params) do
    case Map.get(params, "terms_accepted") do
      value when value in ["true", "on", true] -> :ok
      _ -> {:error, "Terms of service must be accepted"}
    end
  end
end
