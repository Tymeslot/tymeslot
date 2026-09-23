defmodule Tymeslot.Security.RedirectPath do
  @moduledoc """
  Decides whether a redirect target is a safe, same-origin relative path.

  This is the single validator for open-redirect protection: the web layer's
  `TymeslotWeb.Helpers.RedirectSanitizer` delegates here, and so does the
  `return_to` embedded in a signed OAuth state, so a path can never be
  accepted by one and rejected by the other.
  """

  # Browsers strip ASCII tab (0x09), LF (0x0A) and CR (0x0D) from a URL before
  # parsing it, so the string the parser sees is not the string we validated.
  # `/\tevil.com` is validated here as a relative path but fetched as
  # `//evil.com`, a protocol-relative URL pointing at an attacker's host.
  @url_stripped_chars ["\t", "\n", "\r"]

  @doc """
  Returns `true` when `path` is a safe relative path.

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
  - It does not contain a backslash (browsers treat `/\\evil.com` as
    `//evil.com`)
  """
  @spec safe?(term()) :: boolean()
  def safe?(path) when is_binary(path) do
    decoded = URI.decode(path)
    double_decoded = URI.decode(decoded)

    String.starts_with?(path, "/") and
      not String.contains?(path, "://") and
      not String.starts_with?(decoded, "//") and
      not String.starts_with?(double_decoded, "//") and
      not String.contains?(path, "\\") and
      no_stripped_chars?([path, decoded, double_decoded]) and
      is_nil(URI.parse(path).host)
  end

  def safe?(_other), do: false

  @doc """
  Returns `path` if it is a safe relative path (see `safe?/1`), otherwise
  returns `default`.
  """
  @spec sanitize(term(), String.t()) :: String.t()
  def sanitize(path, default), do: if(safe?(path), do: path, else: default)

  # Checked against the decoded forms too: a browser that decodes `%09` before
  # stripping would rebuild the same protocol-relative payload from
  # `/%09/evil.com`.
  defp no_stripped_chars?(forms) do
    Enum.all?(forms, &(not String.contains?(&1, @url_stripped_chars)))
  end
end
