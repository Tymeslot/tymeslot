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

  # Whether a typed URL already carries a scheme. The RFC 3986 §3.1 production
  # allows a dot in a scheme, so it alone cannot tell `ftp://files.example.com`
  # from a typed `cloud.example.com:8443`, which is a host and a port and needs
  # its `https://` as much as a bare hostname does. Two narrower shapes settle
  # it between them: any scheme followed by `//`, which is every hierarchical
  # URL someone could paste into a server field, or a dot-free scheme, which is
  # what the opaque ones (`mailto:`, `javascript:`, `data:`) look like.
  #
  # Both are anchored and both require a leading letter, which is load-bearing:
  # without it `8443:something` would read as carrying a scheme.
  @scheme_prefix ~r{\A(?:[a-zA-Z][a-zA-Z0-9+.-]*://|[a-zA-Z][a-zA-Z0-9+-]*:)}

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

  A URL that already carries a scheme is left exactly as typed, whatever that
  scheme is, so the scheme allow-list downstream can refuse it in its own words.
  Prefix-matching `http://` and `https://` instead glued a second scheme onto
  the front of `ftp://…` and `HTTPS://…` alike, which made every one of them
  fail the *host* check with a message about the host, and rejected a correctly
  typed URL whose scheme a mobile keyboard had autocapitalised.
  """
  @spec normalize_url_protocol(String.t()) :: String.t()
  def normalize_url_protocol(url) do
    trimmed_url = String.trim(url)

    cond do
      trimmed_url == "" -> trimmed_url
      Regex.match?(@scheme_prefix, trimmed_url) -> trimmed_url
      true -> "https://" <> trimmed_url
    end
  end

  @doc """
  Shared server URL validation logic.

  Credentials in the URL itself are refused: `https://user:pass@cloud.example.com`
  parses to a perfectly good host and would be stored verbatim, while every
  screen that renders a connection shows the host alone, so the password would
  sit in a field nothing displays. The username and password fields already
  exist for it.

  A host needs a dot, as a public domain has, unless it is `localhost`. With
  `internal_names_local: true` a single-label internal name (a Docker service
  name such as `nextcloud`, see `Tymeslot.Security.UrlValidation.internal_name?/1`)
  is accepted too; callers pass it exactly when the operator has allowed
  private addresses for the integration, the same opt-in that lets the https
  rule accept such a name.

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
    internal_names_local = Keyword.get(opts, :internal_names_local, false)

    with {:ok, candidate} <-
           UniversalSanitizer.sanitize_and_validate(normalize_url_protocol(url),
             mode: :plain_text,
             metadata: metadata
           ),
         :ok <- validate_url_shape(candidate, error_msg, internal_names_local),
         :ok <- validate_url_fn.(candidate) do
      {:ok, candidate}
    end
  end

  defp validate_url_shape(url, error_msg, internal_names_local) do
    uri = URI.parse(url)

    cond do
      Regex.match?(@forbidden_url_chars, url) ->
        {:error, error_msg}

      is_nil(uri.host) or uri.host == "" ->
        {:error, error_msg}

      not is_nil(uri.userinfo) ->
        {:error,
         dgettext(
           "dashboard_integrations",
           "Enter the address on its own and put the username and password in their own fields."
         )}

      not host_shape_allowed?(uri.host, internal_names_local) ->
        {:error, error_msg}

      true ->
        :ok
    end
  end

  # A public domain has a dot; `localhost` is the one bare name always allowed.
  # A single-label internal name is admitted only under the operator's
  # private-address opt-in.
  defp host_shape_allowed?("localhost", _internal_names_local), do: true

  defp host_shape_allowed?(host, internal_names_local) do
    String.contains?(host, ".") or (internal_names_local and UrlValidation.internal_name?(host))
  end
end
