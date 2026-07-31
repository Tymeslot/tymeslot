defmodule Tymeslot.Integrations.Shared.InputValidators do
  @moduledoc """
  Shared input validators used across multiple integration input validation modules.

  Provides consistent, tagged-tuple validation for common fields like integration name.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.FieldValidators.IntegrationNameValidator
  alias Tymeslot.Security.{InputProcessor, UniversalSanitizer}
  alias Tymeslot.Validation.Constraints

  # See IntegrationNameValidator for the rationale behind this character set.
  @invisible_chars ~r/[\x{200B}-\x{200F}\x{2028}-\x{202F}\x{205F}-\x{206F}\x{FEFF}\x{00AD}]/u

  @spec validate_integration_name(String.t()) :: {:ok, String.t()} | {:error, %{name: String.t()}}
  def validate_integration_name(name) when is_binary(name) do
    cleaned =
      name
      |> String.trim()
      |> String.replace(@invisible_chars, "")

    range = Constraints.integration_name_length_range()

    cond do
      cleaned == "" ->
        {:error, %{name: dgettext("dashboard_integrations", "Name is required")}}

      String.length(cleaned) < range.first ->
        {:error,
         %{
           name:
             dngettext(
               "dashboard_integrations",
               "Name must be at least %{count} character",
               "Name must be at least %{count} characters",
               range.first
             )
         }}

      String.length(cleaned) > range.last ->
        {:error,
         %{
           name:
             dngettext(
               "dashboard_integrations",
               "Name must be %{count} character or less",
               "Name must be %{count} characters or less",
               range.last
             )
         }}

      true ->
        {:ok, cleaned}
    end
  end

  def validate_integration_name(_value),
    do: {:error, %{name: dgettext("dashboard_integrations", "Name must be text")}}

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
      {:ok, sanitized} ->
        {:ok, sanitized |> String.trim() |> String.replace(@invisible_chars, "")}

      {:error, reason} ->
        {:error, %{name: reason}}
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
    error_msg =
      Keyword.get(
        opts,
        :error_message,
        dgettext("dashboard_integrations", "Please enter a valid server URL")
      )

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
