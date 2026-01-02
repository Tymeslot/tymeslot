defmodule Tymeslot.Security.FieldValidators.PasswordValidator do
  @moduledoc """
  Password field validation with security requirements.

  Validates password complexity, length, and security patterns
  while providing specific feedback for security requirements.
  """

  @password_min_length 8
  @password_max_length 80

  @doc """
  Validates password with security requirements and specific error messages.

  ## Examples

      iex> validate("StrongPass123")
      :ok
      
      iex> validate("weak")
      {:error, "Password must be at least 8 characters long"}
      
      iex> validate("nouppercase123")
      {:error, "Password must contain at least one uppercase letter"}
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(password, opts \\ [])

  def validate(nil, _opts), do: {:error, "Password is required"}
  def validate("", _opts), do: {:error, "Password is required"}

  def validate(password, opts) when is_binary(password) do
    min_length = Keyword.get(opts, :min_length, @password_min_length)
    max_length = Keyword.get(opts, :max_length, @password_max_length)

    with :ok <- validate_length(password, min_length, max_length) do
      validate_complexity(password)
    end
  end

  def validate(_password, _opts) do
    {:error, "Password must be a text value"}
  end

  @doc """
  Validates password confirmation matches original password.
  """
  @spec validate_confirmation(any(), any(), keyword()) :: :ok | {:error, String.t()}
  def validate_confirmation(password, confirmation, opts \\ [])

  def validate_confirmation(password, password, _opts) when is_binary(password) do
    :ok
  end

  def validate_confirmation(_password, nil, _opts) do
    {:error, "Password confirmation is required"}
  end

  def validate_confirmation(_password, "", _opts) do
    {:error, "Password confirmation is required"}
  end

  def validate_confirmation(_password, _confirmation, _opts) do
    {:error, "Password confirmation does not match"}
  end

  # Private helper functions

  defp validate_length(password, min_length, max_length) do
    length = String.length(password)

    cond do
      length < min_length ->
        {:error, "Password must be at least #{min_length} characters long"}

      length > max_length ->
        {:error, "Password must be at most #{max_length} characters long"}

      true ->
        :ok
    end
  end

  defp validate_complexity(password) do
    cond do
      not String.match?(password, ~r/[a-z]/) ->
        {:error, "Password must contain at least one lowercase letter"}

      not String.match?(password, ~r/[A-Z]/) ->
        {:error, "Password must contain at least one uppercase letter"}

      not String.match?(password, ~r/[0-9]/) ->
        {:error, "Password must contain at least one number"}

      true ->
        :ok
    end
  end
end
