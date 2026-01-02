defmodule Tymeslot.Security.FieldValidators.TextValidator do
  @moduledoc """
  General text field validation for short text inputs.

  Validates basic text fields like subjects, titles, and other
  short text content with configurable length limits.
  """

  @spec get_config(atom(), keyword()) :: integer() | nil
  def get_config(key, opts \\ []) do
    config = Application.get_env(:tymeslot, :field_validation, [])

    case key do
      :min_length -> Keyword.get(opts, :min_length, config[:text_min_length] || 1)
      :max_length -> Keyword.get(opts, :max_length, config[:text_max_length] || 500)
      _ -> nil
    end
  end

  @doc """
  Validates general text fields with specific error messages.

  ## Options
  - `:min_length` - Minimum length (default: 1)
  - `:max_length` - Maximum length (default: 500)
  - `:required` - Whether field is required (default: true)

  ## Examples

      iex> validate("Hello world")
      :ok
      
      iex> validate("", required: false)
      :ok
      
      iex> validate("")
      {:error, "Text is required"}
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(text, opts \\ [])

  def validate(nil, opts) do
    if Keyword.get(opts, :required, true) do
      {:error, "Text is required"}
    else
      :ok
    end
  end

  def validate("", opts) do
    if Keyword.get(opts, :required, true) do
      {:error, "Text is required"}
    else
      :ok
    end
  end

  def validate(text, opts) when is_binary(text) do
    min_length = get_config(:min_length, opts)
    max_length = get_config(:max_length, opts)

    trimmed_text = String.trim(text)

    cond do
      Keyword.get(opts, :required, true) and trimmed_text == "" ->
        {:error, "Text cannot be blank"}

      String.length(trimmed_text) < min_length and trimmed_text != "" ->
        {:error, "Text is too short (minimum #{min_length} characters)"}

      String.length(trimmed_text) > max_length ->
        {:error, "Text is too long (maximum #{max_length} characters)"}

      true ->
        :ok
    end
  end

  def validate(_text, _opts) do
    {:error, "Text must be a text value"}
  end
end
