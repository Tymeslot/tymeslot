defmodule Tymeslot.Security.FieldValidators.IntegrationNameValidator do
  @moduledoc """
  Validator for integration names used in calendar/video integrations.
  Matches existing behavior and error messages in processors.
  """

  @min_length 2
  @max_length 100

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(nil, _opts), do: {:error, "Integration name is required"}
  def validate("", _opts), do: {:error, "Integration name is required"}

  # Note: universal sanitization happens before this via InputProcessor
  def validate(name, _opts) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      String.length(name) > @max_length ->
        {:error, "Integration name must be 100 characters or less"}

      String.length(trimmed) < @min_length ->
        {:error, "Integration name must be at least 2 characters"}

      true ->
        :ok
    end
  end

  def validate(_other, _opts), do: {:error, "Integration name must be text"}
end
