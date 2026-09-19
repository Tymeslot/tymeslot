defmodule Tymeslot.Integrations.Shared.InputValidators do
  @moduledoc """
  Shared input validators used across multiple integration input validation modules.

  Provides consistent, tagged-tuple validation for common fields like integration name.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.FieldValidators.IntegrationNameValidator
  alias Tymeslot.Security.{InputProcessor, UniversalSanitizer, UrlValidation}

  # See IntegrationNameValidator for the rationale behind this character set.
  @invisible_chars ~r/[\x{200B}-\x{200F}\x{2028}-\x{202F}\x{205F}-\x{206F}\x{FEFF}\x{00AD}]/u

  # A server URL is stored exactly as typed and later requested, so it may not
  # carry characters that have no place in one: whitespace (`\p{Z}`) and the
  # control, format and other invisible characters (`\p{C}`) that split a
  # request line or make one hostname read as another. These are refused
  # rather than stripped: quietly editing a URL is what this validator exists
  # not to do.
  @forbidden_url_chars ~r/[\p{Z}\p{C}]/u

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

  The URL is sanitised in `:plain_text` mode, not the default `:strict`.
  Strict mode is built for free text and rewrites a URL without saying so: it
  percent-decodes repeatedly and then strips SQL-comment-shaped (`--…`) and
  hex-shaped (`0x…`) runs, so `https://meet.example.com/team--sync` would be
  stored as `https://meet.example.com/team` and `…/room%23a` would become a
  fragment the server never sees. The result still parses, so the save
  succeeds and every booking points at a different room. Calendar feed URLs
  already bypass this function for exactly that reason
  (`Tymeslot.Integrations.Calendar.InputValidation`).

  Plain-text mode still validates UTF-8, strips null bytes, normalises to NFC
  and enforces the length limits. Safety comes from `validate_url_fn`, which
  defaults to the HTTP/HTTPS allow-list in `Tymeslot.Security.UrlValidation`:
  a URL is bound to queries as a parameter and escaped on render, so there is
  nothing here for strict mode to protect that it does not break first.
  """
  @spec validate_server_url(any(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_server_url(url, metadata, opts \\ []) do
    error_msg =
      Keyword.get(
        opts,
        :error_message,
        dgettext("dashboard_integrations", "Please enter a valid server URL")
      )

    validate_url_fn = Keyword.get(opts, :validate_url_fn, &UrlValidation.validate_http_url/1)

    with {:ok, candidate} <-
           UniversalSanitizer.sanitize_and_validate(normalize_url_protocol(url),
             mode: :plain_text,
             metadata: metadata
           ),
         :ok <- validate_url_shape(candidate, error_msg),
         :ok <- validate_url_fn.(candidate) do
      {:ok, candidate}
    end
  end

  defp validate_url_shape(url, error_msg) do
    uri = URI.parse(url)

    cond do
      Regex.match?(@forbidden_url_chars, url) ->
        {:error, error_msg}

      is_nil(uri.host) or uri.host == "" ->
        {:error, error_msg}

      # Require at least one dot for public domains, or allow 'localhost'
      not String.contains?(uri.host, ".") and uri.host != "localhost" ->
        {:error, error_msg}

      true ->
        :ok
    end
  end
end
