defmodule Tymeslot.Auth.Validation do
  @moduledoc """
  Domain validation logic for authentication flows.

  This module contains all authentication-specific validation logic,
  keeping it within the Auth bounded context according to DDD principles.
  """

  alias Tymeslot.Auth.ErrorFormatter
  alias Tymeslot.Security.FieldValidators.PasswordValidator
  alias Tymeslot.Security.InputProcessor

  @type login_params :: %{String.t() => term()}
  @type signup_params :: %{String.t() => term()}
  @type password_reset_request :: %{String.t() => term()}
  @type password_reset_new :: %{String.t() => term()}

  @doc """
  Validates user login input, sanitizing the email via InputProcessor.

  ## Parameters
  - params: Map containing "email" and "password" fields

  ## Returns
  - {:ok, sanitized_params} if validation passes
  - {:error, errors} if validation fails
  """
  @spec validate_login_input(login_params()) ::
          {:ok, login_params()} | {:error, %{atom() => String.t()}}
  def validate_login_input(params) do
    {email_errors, sanitized_email} =
      case InputProcessor.validate_field(params["email"], :email) do
        {:ok, sanitized} -> {%{}, sanitized}
        {:error, msg} -> {%{email: msg}, params["email"]}
      end

    errors =
      cond do
        is_nil(params["password"]) or params["password"] == "" ->
          Map.put(email_errors, :password, "can't be blank")

        byte_size(params["password"]) > 1024 ->
          Map.put(email_errors, :password, "Password is too long")

        true ->
          email_errors
      end

    if map_size(errors) == 0 do
      {:ok, Map.put(params, "email", sanitized_email)}
    else
      {:error, errors}
    end
  end

  @doc """
  Validates user signup/registration input.

  ## Parameters
  - params: Map containing registration fields

  ## Returns
  - {:ok, params} if validation passes
  - {:error, errors} if validation fails
  """
  @spec validate_signup_input(signup_params()) ::
          {:ok, signup_params()} | {:error, %{atom() => [String.t()]}}
  def validate_signup_input(params) do
    InputProcessor.validate_form(params, [
      {"email", :email},
      {"password", :password},
      {"full_name", :full_name}
    ])
  end

  @doc """
  Validates password reset request input.

  ## Parameters
  - params: Map containing "email" field

  ## Returns
  - {:ok, params} if validation passes
  - {:error, errors} if validation fails
  """
  @spec validate_password_reset_input(password_reset_request() | password_reset_new()) ::
          {:ok, password_reset_request() | password_reset_new()}
          | {:error, %{atom() => [String.t()]}}
  def validate_password_reset_input(params) do
    InputProcessor.validate_form(params, [{"email", :email}])
  end

  @doc """
  Validates new password input for password reset, including confirmation match.

  ## Parameters
  - params: Map containing "password" and "password_confirmation" fields

  ## Returns
  - {:ok, sanitized_params} if validation passes
  - {:error, errors} if validation fails
  """
  @spec validate_new_password_input(password_reset_new()) ::
          {:ok, password_reset_new()} | {:error, %{atom() => String.t() | [String.t()]}}
  def validate_new_password_input(params) do
    with {:ok, sanitized} <-
           InputProcessor.validate_form(params, [
             {"password", :password},
             {"password_confirmation", :password}
           ]),
         :ok <-
           PasswordValidator.validate_confirmation(
             sanitized["password"],
             sanitized["password_confirmation"]
           ) do
      {:ok, sanitized}
    else
      {:error, errors} when is_map(errors) -> {:error, errors}
      {:error, msg} -> {:error, %{password_confirmation: msg}}
    end
  end

  @doc """
  Formats validation errors for display.

  ## Parameters
  - errors: Map of field errors or changeset

  ## Returns
  Formatted error string or map suitable for display
  """
  @spec format_validation_errors(any()) :: String.t() | map()
  def format_validation_errors(errors) when is_map(errors) do
    ErrorFormatter.format_validation_errors(errors)
  end

  def format_validation_errors({:error, errors}) when is_map(errors) do
    format_validation_errors(errors)
  end

  def format_validation_errors(_input), do: "Invalid input provided."
end
