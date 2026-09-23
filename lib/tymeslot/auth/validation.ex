defmodule Tymeslot.Auth.Validation do
  @moduledoc """
  Domain validation logic for authentication flows.

  This module contains all authentication-specific validation logic,
  keeping it within the Auth bounded context according to DDD principles.
  """

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Security.FieldValidators.PasswordValidator
  alias Tymeslot.Security.{InputProcessor, Password}

  # Matches the bound login applies before hashing, so a pasted megabyte
  # cannot be used to burn bcrypt time.
  @max_current_password_bytes 1024

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

  @doc """
  Checks the current password a signed-in user re-enters to confirm a
  sensitive change (email or password).

  It is held to login's rules, not the creation policy: it must be present
  and at most #{@max_current_password_bytes} bytes. An account with no
  password (signed up through a social provider) never matches, and costs
  the same bcrypt time as a mismatch.
  """
  @spec check_current_password(UserSchema.t(), term()) ::
          :ok | {:error, :missing_password | :invalid_password}
  def check_current_password(%{password_hash: hash}, password) do
    cond do
      not is_binary(password) or password == "" ->
        {:error, :missing_password}

      byte_size(password) > @max_current_password_bytes ->
        {:error, :invalid_password}

      is_nil(hash) ->
        Password.no_user_verify()
        {:error, :invalid_password}

      Password.verify_password(password, hash) ->
        :ok

      true ->
        {:error, :invalid_password}
    end
  end
end
