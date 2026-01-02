defmodule Tymeslot.Auth.Validation do
  @moduledoc """
  Domain validation logic for authentication flows.

  This module contains all authentication-specific validation logic,
  keeping it within the Auth bounded context according to DDD principles.
  """

  alias Tymeslot.Auth.ErrorFormatter
  alias Tymeslot.Security.AuthValidation

  @doc """
  Validates user login input.

  ## Parameters
  - params: Map containing "email" and "password" fields

  ## Returns
  - {:ok, params} if validation passes
  - {:error, errors} if validation fails
  """
  @spec validate_login_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_login_input(params) do
    errors = %{}

    errors =
      if is_nil(params["email"]) or params["email"] == "" do
        Map.put(errors, :email, ["can't be blank"])
      else
        errors
      end

    errors =
      if is_nil(params["password"]) or params["password"] == "" do
        Map.put(errors, :password, ["can't be blank"])
      else
        errors
      end

    if map_size(errors) == 0 do
      {:ok, params}
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
  @spec validate_signup_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_signup_input(params) do
    # Delegate to existing AuthValidation module for now
    # This will be refactored in a future iteration
    AuthValidation.validate_signup_input(params)
  end

  @doc """
  Validates password reset request input.

  ## Parameters
  - params: Map containing "email" field

  ## Returns
  - {:ok, params} if validation passes
  - {:error, errors} if validation fails
  """
  @spec validate_password_reset_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_password_reset_input(params) do
    # Delegate to existing AuthValidation module for now
    # This will be refactored in a future iteration
    AuthValidation.validate_password_reset_input(params)
  end

  @doc """
  Validates new password input for password reset.

  ## Parameters
  - params: Map containing "password" and "password_confirmation" fields

  ## Returns
  - {:ok, params} if validation passes
  - {:error, errors} if validation fails
  """
  @spec validate_new_password_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_new_password_input(params) do
    # Delegate to existing AuthValidation module for now
    # This will be refactored in a future iteration
    AuthValidation.validate_password_reset_input(params)
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

  def format_validation_errors(%Ecto.Changeset{} = changeset) do
    ErrorFormatter.format_changeset_errors(changeset)
  end

  def format_validation_errors(_), do: "Invalid input provided."
end
