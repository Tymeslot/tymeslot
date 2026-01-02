defmodule Tymeslot.Security.FieldValidators.MessageValidator do
  @moduledoc """
  Message field validation for longer text content.

  Validates longer text fields like messages, descriptions, and comments
  with appropriate length limits and optional HTML content support.
  """

  @message_min_length 10
  @message_max_length 2000

  @doc """
  Validates message fields with specific error messages.

  ## Options
  - `:min_length` - Minimum length (default: 10)
  - `:max_length` - Maximum length (default: 2000)
  - `:required` - Whether field is required (default: true)

  ## Examples

      iex> validate("This is a longer message with enough content")
      :ok
      
      iex> validate("Short")
      {:error, "Message is too short (minimum 10 characters)"}
      
      iex> validate("")
      {:error, "Message is required"}
  """
  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(message, opts \\ [])

  def validate(nil, opts) do
    if Keyword.get(opts, :required, true) do
      {:error, "Message is required"}
    else
      :ok
    end
  end

  def validate("", opts) do
    if Keyword.get(opts, :required, true) do
      {:error, "Message is required"}
    else
      :ok
    end
  end

  def validate(message, opts) when is_binary(message) do
    min_length = Keyword.get(opts, :min_length, @message_min_length)
    max_length = Keyword.get(opts, :max_length, @message_max_length)

    trimmed_message = String.trim(message)

    cond do
      Keyword.get(opts, :required, true) and trimmed_message == "" ->
        {:error, "Message cannot be blank"}

      String.length(trimmed_message) < min_length and trimmed_message != "" ->
        {:error, "Message is too short (minimum #{min_length} characters)"}

      String.length(trimmed_message) > max_length ->
        {:error, "Message is too long (maximum #{max_length} characters)"}

      only_whitespace_and_punctuation?(trimmed_message) ->
        {:error, "Message must contain meaningful content"}

      true ->
        :ok
    end
  end

  def validate(_message, _opts) do
    {:error, "Message must be a text value"}
  end

  # Private helper functions

  defp only_whitespace_and_punctuation?(message) do
    # Check if message only contains spaces, punctuation, and special characters
    cleaned = String.replace(message, ~r/[\s\p{P}\p{S}]/u, "")
    String.length(cleaned) < 3
  end
end
