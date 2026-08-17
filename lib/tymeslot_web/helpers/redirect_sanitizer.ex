defmodule TymeslotWeb.Helpers.RedirectSanitizer do
  @moduledoc """
  Validates redirect paths to prevent open redirect vulnerabilities.

  Only accepts relative paths (starting with "/") that do not contain
  scheme separators, protocol-relative prefixes, backslashes, URL-stripped
  control characters, or a host component.
  """

  # Browsers strip ASCII tab (0x09), LF (0x0A) and CR (0x0D) from a URL before
  # parsing it, so the string the parser sees is not the string we validated.
  # `/\tevil.com` is validated here as a relative path but fetched as
  # `//evil.com`, a protocol-relative URL pointing at an attacker's host.
  @url_stripped_chars ["\t", "\n", "\r"]

  @doc """
  Returns `path` if it is a safe relative path, otherwise returns `default`.

  A path is considered safe when all of the following hold:
  - It starts with "/"
  - It does not contain "://" (scheme separator)
  - The URL-decoded form does not start with "//" (protocol-relative)
  - The double URL-decoded form does not start with "//" (catches double-encoded
    protocol-relative payloads such as `/%252F%252Fevil.com` which a browser
    decoding twice would resolve to `//evil.com`)
  - Neither it nor either decoded form contains an ASCII tab, LF or CR. Browsers
    strip these before parsing, so `/\\t/evil.com` would otherwise pass every
    check above and still resolve to `//evil.com`
  - `URI.parse/1` finds no host component (rules out "//host/path" forms)
  - It does not contain a backslash (rules out path confusion tricks)
  """
  @spec sanitize(String.t() | nil, String.t()) :: String.t()
  def sanitize(path, default) do
    case path do
      p when is_binary(p) ->
        decoded = URI.decode(p)
        double_decoded = URI.decode(decoded)

        if String.starts_with?(p, "/") and
             not String.contains?(p, "://") and
             not String.starts_with?(decoded, "//") and
             not String.starts_with?(double_decoded, "//") and
             not String.contains?(p, "\\") and
             no_stripped_chars?([p, decoded, double_decoded]) and
             is_nil(URI.parse(p).host) do
          p
        else
          default
        end

      _other ->
        default
    end
  end

  # Checked against the decoded forms too: a browser that decodes `%09` before
  # stripping would rebuild the same protocol-relative payload from
  # `/%09/evil.com`.
  defp no_stripped_chars?(forms) do
    Enum.all?(forms, &(not String.contains?(&1, @url_stripped_chars)))
  end
end
