defmodule Tymeslot.Integrations.Shared.InputValidators do
  @moduledoc """
  Shared input validators used across multiple integration input validation modules.

  Provides consistent, tagged-tuple validation for common fields like integration name.
  """

  alias Tymeslot.Security.FieldValidators.IntegrationNameValidator
  alias Tymeslot.Security.{InputProcessor, UniversalSanitizer}

  @spec validate_integration_name(String.t()) :: {:ok, String.t()} | {:error, %{name: String.t()}}
  def validate_integration_name(name) when is_binary(name) do
    cleaned = String.trim(name)

    cond do
      cleaned == "" -> {:error, %{name: "Name is required"}}
      String.length(cleaned) > 120 -> {:error, %{name: "Name must be 120 characters or less"}}
      true -> {:ok, cleaned}
    end
  end

  def validate_integration_name(_value), do: {:error, %{name: "Name must be text"}}

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

  @doc """
  Normalizes a URL by adding https:// if no protocol is present.
  """
  @spec normalize_url_protocol(String.t()) :: String.t()
  def normalize_url_protocol(url) do
    trimmed_url = String.trim(url)

    cond do
      # Already has a protocol
      String.starts_with?(trimmed_url, ["http://", "https://"]) ->
        trimmed_url

      # No protocol - add https://
      trimmed_url != "" ->
        "https://" <> trimmed_url

      # Empty string
      true ->
        trimmed_url
    end
  end

  @doc """
  Shared server URL validation logic.
  """
  @spec validate_server_url(any(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_server_url(url, metadata, opts \\ []) do
    error_msg = Keyword.get(opts, :error_message, "Please enter a valid server URL")
    validate_url_fn = Keyword.get(opts, :validate_url_fn, fn _url -> :ok end)

    case UniversalSanitizer.sanitize_and_validate(normalize_url_protocol(url),
           allow_html: false,
           metadata: metadata
         ) do
      {:ok, sanitized_url} ->
        uri = URI.parse(sanitized_url)

        cond do
          is_nil(uri.host) or uri.host == "" ->
            {:error, error_msg}

          # Require at least one dot for public domains, or allow 'localhost'
          not String.contains?(uri.host, ".") and uri.host != "localhost" ->
            {:error, error_msg}

          true ->
            case validate_url_fn.(sanitized_url) do
              :ok -> {:ok, sanitized_url}
              {:error, error} -> {:error, error}
            end
        end

      {:error, error} ->
        {:error, error}
    end
  end
end
