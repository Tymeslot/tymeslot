defmodule Tymeslot.Security.SharedInputValidators do
  @moduledoc """
  Shared input validators used across multiple integration input processors.

  Provides consistent, tagged-tuple validation for common fields like integration name.
  """

  alias Tymeslot.Security.FieldValidators.IntegrationNameValidator
  alias Tymeslot.Security.InputProcessor

  @spec validate_integration_name(String.t()) :: {:ok, String.t()} | {:error, %{name: String.t()}}
  def validate_integration_name(name) when is_binary(name) do
    cleaned = String.trim(name)

    cond do
      cleaned == "" -> {:error, %{name: "Name is required"}}
      String.length(cleaned) > 120 -> {:error, %{name: "Name must be 120 characters or less"}}
      true -> {:ok, cleaned}
    end
  end

  def validate_integration_name(_), do: {:error, %{name: "Name must be text"}}

  @doc """
  Strict, centralized validator for integration names with universal sanitization.

  This function is the preferred entrypoint for processors. It uses the
  IntegrationNameValidator (min length 2, max 100) and universal sanitization
  with HTML disallowed, and returns tagged tuples consistent with processors.
  """
  @spec validate_integration_name(any(), map()) ::
          {:ok, String.t()} | {:error, %{name: String.t()}}
  def validate_integration_name(value, metadata) do
    case InputProcessor.validate_field(value, IntegrationNameValidator,
           universal_opts: [allow_html: false],
           metadata: metadata
         ) do
      {:ok, sanitized} -> {:ok, String.trim(sanitized)}
      {:error, reason} -> {:error, %{name: reason}}
    end
  end
end
