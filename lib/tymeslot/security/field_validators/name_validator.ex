defmodule Tymeslot.Security.FieldValidators.NameValidator do
  @moduledoc """
  Name field validation for person names, company names, etc.

  Validates name fields with appropriate length limits and
  character restrictions while allowing international names.
  """

  @name_min_length 2
  @name_max_length 100
  @invalid_chars_regex ~r/[<>"%;`\\\/\{\}\[\]]/

  @doc """
  Validates name fields with specific error messages.

  ## Examples

      iex> validate("John Smith")
      :ok
      
      iex> validate("José María")
      :ok
      
      iex> validate("A")
      {:error, "Name is too short (minimum 2 characters)"}
      
      iex> validate("John<script>")
      {:error, "Name contains invalid characters"}
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(name, opts \\ [])

  def validate(nil, _opts), do: {:error, "Name is required"}
  def validate("", _opts), do: {:error, "Name is required"}

  def validate(name, opts) when is_binary(name) do
    min_length = Keyword.get(opts, :min_length, @name_min_length)
    max_length = Keyword.get(opts, :max_length, @name_max_length)

    trimmed_name = String.trim(name)

    cond do
      trimmed_name == "" ->
        {:error, "Name cannot be blank"}

      String.length(trimmed_name) < min_length ->
        {:error, "Name is too short (minimum #{min_length} characters)"}

      String.length(trimmed_name) > max_length ->
        {:error, "Name is too long (maximum #{max_length} characters)"}

      Regex.match?(@invalid_chars_regex, trimmed_name) ->
        {:error, "Name contains invalid characters"}

      all_numbers?(trimmed_name) ->
        {:error, "Name cannot be only numbers"}

      excessive_whitespace?(trimmed_name) ->
        {:error, "Name contains excessive whitespace"}

      true ->
        :ok
    end
  end

  def validate(_name, _opts) do
    {:error, "Name must be a text value"}
  end

  # Private helper functions

  defp all_numbers?(name) do
    Regex.match?(~r/^\d+$/, String.replace(name, " ", ""))
  end

  defp excessive_whitespace?(name) do
    # Check for more than 2 consecutive spaces
    Regex.match?(~r/\s{3,}/, name)
  end
end
