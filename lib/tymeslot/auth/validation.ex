defmodule Tymeslot.Auth.Validation do
  @moduledoc """
  Domain validation logic for authentication flows.

  This module contains all authentication-specific validation logic,
  keeping it within the Auth bounded context according to DDD principles.
  """

  alias Tymeslot.Security.FieldValidators.PasswordValidator
  alias Tymeslot.Security.InputProcessor

  @type signup_params :: %{String.t() => term()}
  @type password_reset_new :: %{String.t() => term()}

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
end
