defmodule Tymeslot.Security.FieldValidators.UsernameValidator do
  @moduledoc """
  Username field validation for onboarding.

  Validates username format, length, and character restrictions
  for creating public scheduling URLs.
  """

  @username_min_length 3
  @username_max_length 30
  @username_regex ~r/^[a-z0-9][a-z0-9_-]*$/

  @doc """
  Validates username with specific error messages.

  ## Examples

      iex> validate("john_smith")
      :ok

      iex> validate("ab")
      {:error, "Username must be at least 3 characters long"}

      iex> validate("john@smith")
      {:error, "Username must start with a letter or number and contain only lowercase letters, numbers, underscores, and hyphens"}
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(username, opts \\ [])

  def validate(nil, _opts), do: {:error, "Username is required"}
  def validate("", _opts), do: {:error, "Username is required"}

  def validate(username, opts) when is_binary(username) do
    min_length = Keyword.get(opts, :min_length, @username_min_length)
    max_length = Keyword.get(opts, :max_length, @username_max_length)
    reserved_words = Keyword.get(opts, :reserved_words, nil)

    trimmed_username = String.trim(username)

    with :ok <- validate_length(trimmed_username, min_length, max_length),
         :ok <- validate_format(trimmed_username) do
      validate_reserved_words(trimmed_username, reserved_words)
    end
  end

  def validate(_username, _opts) do
    {:error, "Username must be a text value"}
  end

  # Private helper functions

  defp validate_length(username, min_length, max_length) do
    length = String.length(username)

    cond do
      length < min_length ->
        {:error, "Username must be at least #{min_length} characters long"}

      length > max_length ->
        {:error, "Username must be at most #{max_length} characters long"}

      true ->
        :ok
    end
  end

  defp validate_format(username) do
    if Regex.match?(@username_regex, username) do
      :ok
    else
      {:error,
       "Username must start with a letter or number and contain only lowercase letters, numbers, underscores, and hyphens"}
    end
  end

  defp validate_reserved_words(_username, nil), do: :ok

  defp validate_reserved_words(username, reserved_words) when is_list(reserved_words) do
    lowercase_username = String.downcase(username)

    if lowercase_username in reserved_words do
      {:error, "This username is reserved"}
    else
      :ok
    end
  end
end
