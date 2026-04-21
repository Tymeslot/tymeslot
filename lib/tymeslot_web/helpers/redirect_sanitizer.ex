defmodule TymeslotWeb.Helpers.RedirectSanitizer do
  @moduledoc """
  Validates redirect paths to prevent open redirect vulnerabilities.

  Only accepts relative paths (starting with "/") that do not contain
  scheme separators, protocol-relative prefixes, backslashes, or a host component.
  """

  @doc """
  Returns `path` if it is a safe relative path, otherwise returns `default`.

  A path is considered safe when all of the following hold:
  - It starts with "/"
  - It does not contain "://" (scheme separator)
  - The URL-decoded form does not start with "//" (protocol-relative)
  - The double URL-decoded form does not start with "//" (catches double-encoded
    protocol-relative payloads such as `/%252F%252Fevil.com` which a browser
    decoding twice would resolve to `//evil.com`)
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
             is_nil(URI.parse(p).host) do
          p
        else
          default
        end

      _other ->
        default
    end
  end
end
