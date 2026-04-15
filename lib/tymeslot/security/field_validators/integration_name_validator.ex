defmodule Tymeslot.Security.FieldValidators.IntegrationNameValidator do
  @moduledoc """
  Validator for integration names used in calendar/video integrations.
  Matches existing behavior and error messages in processors.
  """

  @min_length 2
  @max_length 100

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(name, opts \\ [])
  def validate(nil, _opts), do: {:error, "Integration name is required"}
  def validate("", _opts), do: {:error, "Integration name is required"}

  # Matches zero-width spaces (U+200B–U+200F), line/paragraph separators
  # (U+2028–U+202F), Unicode invisible formatting characters (U+2060–U+206F),
  # MEDIUM MATHEMATICAL SPACE (U+205F, which has no business in an integration name),
  # BOM (U+FEFF), and soft hyphen (U+00AD) — characters that survive String.trim/1
  # but produce visually empty or misleading names.
  @invisible_chars ~r/[\x{200B}-\x{200F}\x{2028}-\x{202F}\x{205F}-\x{206F}\x{FEFF}\x{00AD}]/u

  # Note: universal sanitization happens before this via InputProcessor
  def validate(name, _opts) when is_binary(name) do
    trimmed =
      name
      |> String.trim()
      |> String.replace(@invisible_chars, "")

    trimmed_length = String.length(trimmed)

    cond do
      trimmed_length > @max_length ->
        {:error, "Integration name must be 100 characters or less"}

      trimmed_length < @min_length ->
        {:error, "Integration name must be at least 2 characters"}

      true ->
        :ok
    end
  end

  def validate(_other, _opts), do: {:error, "Integration name must be text"}
end
