defmodule Tymeslot.Security.FieldValidators.NameValidator do
  @moduledoc """
  Name field validation for person names, company names, etc.

  Validates name fields with appropriate length limits and
  character restrictions while allowing international names.

  Options:

    * `:required` (default `true`): when `false`, a missing or blank name
      is valid.
    * `:min_length` (default 2) and `:max_length` (default 100), counted
      on the trimmed name.

  An optional display name (the `:full_name` field type in
  `Tymeslot.Security.InputProcessor`) is `required: false, min_length: 1`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @name_min_length 2
  @name_max_length 100
  # Control characters too: a name ends up in email headers, where a line
  # break inside it has no business.
  @invalid_chars_regex ~r/[<>"%;`\\\/\{\}\[\]\x00-\x1F\x7F]/

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

  def validate(nil, opts), do: blank_result(opts)
  def validate("", opts), do: blank_result(opts)

  def validate(name, opts) when is_binary(name) do
    min_length = Keyword.get(opts, :min_length, @name_min_length)
    max_length = Keyword.get(opts, :max_length, @name_max_length)

    trimmed_name = String.trim(name)

    cond do
      trimmed_name == "" ->
        if Keyword.get(opts, :required, true),
          do: {:error, dgettext("errors_input", "Name cannot be blank")},
          else: :ok

      String.length(trimmed_name) < min_length ->
        {:error,
         dgettext("errors_input", "Name is too short (minimum %{min_length} characters)",
           min_length: min_length
         )}

      String.length(trimmed_name) > max_length ->
        {:error,
         dgettext("errors_input", "Name is too long (maximum %{max_length} characters)",
           max_length: max_length
         )}

      Regex.match?(@invalid_chars_regex, trimmed_name) ->
        {:error, dgettext("errors_input", "Name contains invalid characters")}

      all_numbers?(trimmed_name) ->
        {:error, dgettext("errors_input", "Name cannot be only numbers")}

      excessive_whitespace?(trimmed_name) ->
        {:error, dgettext("errors_input", "Name contains excessive whitespace")}

      true ->
        :ok
    end
  end

  def validate(_name, _opts) do
    {:error, dgettext("errors_input", "Name must be a text value")}
  end

  # Private helper functions

  defp all_numbers?(name) do
    Regex.match?(~r/^\d+$/, String.replace(name, " ", ""))
  end

  defp excessive_whitespace?(name) do
    # Check for more than 2 consecutive spaces
    Regex.match?(~r/\s{3,}/, name)
  end

  defp blank_result(opts) do
    if Keyword.get(opts, :required, true) do
      {:error, dgettext("errors_input", "Name is required")}
    else
      :ok
    end
  end
end
