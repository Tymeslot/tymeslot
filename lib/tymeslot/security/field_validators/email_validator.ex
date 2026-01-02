defmodule Tymeslot.Security.FieldValidators.EmailValidator do
  @moduledoc """
  Email field validation with precise error messages.

  Validates email format without domain existence checking,
  providing specific feedback for common email format issues.
  """

  @email_max_length 254
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @doc """
  Validates email format with specific error messages.

  ## Examples

      iex> validate("user@example.com")
      :ok
      
      iex> validate("userexample.com")
      {:error, "Email format is invalid (missing @ symbol)"}
      
      iex> validate("user@")
      {:error, "Email domain is missing"}
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(email, opts \\ [])

  def validate(nil, _opts), do: {:error, "Email is required"}
  def validate("", _opts), do: {:error, "Email is required"}

  def validate(email, opts) when is_binary(email) do
    max_length = Keyword.get(opts, :max_length, @email_max_length)

    with :ok <- validate_length(email, max_length),
         :ok <- validate_basic_format(email) do
      validate_advanced_format(email)
    end
  end

  def validate(_email, _opts) do
    {:error, "Email must be a text value"}
  end

  # Private helper functions

  defp validate_length(email, max_length) do
    if String.length(email) > max_length do
      {:error, "Email exceeds maximum length (#{max_length} characters)"}
    else
      :ok
    end
  end

  defp validate_basic_format(email) do
    cond do
      not String.contains?(email, "@") ->
        {:error, "Email format is invalid (missing @ symbol)"}

      String.ends_with?(email, "@") ->
        {:error, "Email domain is missing"}

      String.starts_with?(email, "@") ->
        {:error, "Email username is missing"}

      String.contains?(email, "..") ->
        {:error, "Email format is invalid (consecutive dots not allowed)"}

      String.contains?(email, " ") ->
        {:error, "Email format is invalid (spaces not allowed)"}

      true ->
        :ok
    end
  end

  defp validate_advanced_format(email) do
    cond do
      not Regex.match?(@email_regex, email) ->
        {:error, "Email format is invalid"}

      multiple_at_symbols?(email) ->
        {:error, "Email format is invalid (multiple @ symbols)"}

      invalid_domain_format?(email) ->
        {:error, "Email domain format is invalid"}

      true ->
        :ok
    end
  end

  defp multiple_at_symbols?(email) do
    email
    |> String.graphemes()
    |> Enum.count(&(&1 == "@")) > 1
  end

  defp invalid_domain_format?(email) do
    [_username, domain] = String.split(email, "@", parts: 2)

    cond do
      String.starts_with?(domain, ".") -> true
      String.ends_with?(domain, ".") -> true
      not String.contains?(domain, ".") -> true
      String.length(domain) < 3 -> true
      true -> false
    end
  end
end
