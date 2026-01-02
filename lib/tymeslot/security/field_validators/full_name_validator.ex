defmodule Tymeslot.Security.FieldValidators.FullNameValidator do
  @moduledoc """
  Full name field validation for user registration.

  Validates full name with appropriate length limits while allowing
  international names and handling optional name fields.
  """

  @name_max_length 100
  @invalid_chars_regex ~r/[<>"%;`\\\/\{\}\[\]]/

  @doc """
  Validates full name fields with specific error messages.

  Note: Full name is optional during signup, so empty values are allowed.

  ## Examples

      iex> validate("John Smith")
      :ok
      
      iex> validate("")
      :ok
      
      iex> validate("José María")
      :ok
      
      iex> validate("John<script>")
      {:error, "Full name contains invalid characters"}
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(full_name, opts \\ [])

  def validate(nil, _opts), do: :ok
  def validate("", _opts), do: :ok

  def validate(full_name, opts) when is_binary(full_name) do
    max_length = Keyword.get(opts, :max_length, @name_max_length)

    trimmed_name = String.trim(full_name)

    # Allow empty after trimming (optional field)
    if trimmed_name == "" do
      :ok
    else
      validate_non_empty_name(trimmed_name, max_length)
    end
  end

  def validate(_full_name, _opts) do
    {:error, "Full name must be a text value"}
  end

  # Private helper functions

  defp validate_non_empty_name(name, max_length) do
    cond do
      String.length(name) > max_length ->
        {:error, "Full name is too long (maximum #{max_length} characters)"}

      Regex.match?(@invalid_chars_regex, name) ->
        {:error, "Full name contains invalid characters"}

      all_numbers?(name) ->
        {:error, "Full name cannot be only numbers"}

      excessive_whitespace?(name) ->
        {:error, "Full name contains excessive whitespace"}

      true ->
        :ok
    end
  end

  defp all_numbers?(name) do
    Regex.match?(~r/^\d+$/, String.replace(name, " ", ""))
  end

  defp excessive_whitespace?(name) do
    # Check for more than 2 consecutive spaces
    Regex.match?(~r/\s{3,}/, name)
  end
end
