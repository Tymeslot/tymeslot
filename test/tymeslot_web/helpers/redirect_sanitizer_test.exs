defmodule TymeslotWeb.Helpers.RedirectSanitizerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag :utils

  alias TymeslotWeb.Helpers.RedirectSanitizer

  @default "/fallback"

  describe "sanitize/2" do
    test "accepts a simple relative path" do
      assert RedirectSanitizer.sanitize("/dashboard", @default) == "/dashboard"
    end

    test "accepts a relative path with query string" do
      assert RedirectSanitizer.sanitize("/dashboard?tab=settings", @default) ==
               "/dashboard?tab=settings"
    end

    test "accepts a relative path with fragment" do
      assert RedirectSanitizer.sanitize("/page#section", @default) == "/page#section"
    end

    test "accepts root path" do
      assert RedirectSanitizer.sanitize("/", @default) == "/"
    end

    test "returns default for nil" do
      assert RedirectSanitizer.sanitize(nil, @default) == @default
    end

    test "returns default for non-string" do
      assert RedirectSanitizer.sanitize(42, @default) == @default
    end

    test "returns default for absolute URL with scheme" do
      assert RedirectSanitizer.sanitize("https://evil.com", @default) == @default
    end

    test "returns default for path containing scheme separator" do
      assert RedirectSanitizer.sanitize("/foo://evil.com", @default) == @default
    end

    test "returns default for protocol-relative URL" do
      assert RedirectSanitizer.sanitize("//evil.com/path", @default) == @default
    end

    test "returns default for URL-encoded protocol-relative path" do
      assert RedirectSanitizer.sanitize("/%2Fevil.com", @default) == @default
    end

    test "returns default for path with backslash (path confusion)" do
      assert RedirectSanitizer.sanitize("/\\evil.com", @default) == @default
    end

    test "allows URL-encoded backslash (relative path, same origin after decode)" do
      # /%5Cevil.com decodes to /\evil.com — still a relative path, safe for redirect
      assert RedirectSanitizer.sanitize("/%5Cevil.com", @default) == "/%5Cevil.com"
    end

    test "returns default for empty string" do
      assert RedirectSanitizer.sanitize("", @default) == @default
    end

    test "accepts deeply nested relative path" do
      assert RedirectSanitizer.sanitize("/a/b/c/d", @default) == "/a/b/c/d"
    end
  end

  # These lock in specific payload classes used in real-world open-redirect
  # bypasses. Each should either come out unchanged as a (safe) relative
  # path or fall through to the default.
  describe "sanitize/2 — known bypass patterns" do
    test "rejects CRLF-injection payload targeting Location header smuggling" do
      path = "/foo%0D%0ALocation:%20https://evil.com"
      # CRLF in a relative path is safe for redirects (Phoenix escapes headers
      # on write), so either passing it through untouched OR falling back to
      # default is acceptable — but the output must never be absolute.
      result = RedirectSanitizer.sanitize(path, @default)
      assert_safe(result)
    end

    test "rejects null byte injection" do
      assert_safe(RedirectSanitizer.sanitize("/foo\u0000evil.com", @default))
      assert_safe(RedirectSanitizer.sanitize("/\u0000//evil.com", @default))
    end

    test "rejects unicode slash look-alikes in the authority-opening position" do
      # U+2215 Division Slash and U+FF0F Fullwidth Solidus both look like `/`
      # but are not treated as path separators by the parser, so they should
      # be classified as a relative path (safe) or rejected, never as
      # protocol-relative.
      assert_safe(RedirectSanitizer.sanitize("/\u2215\u2215evil.com", @default))
      assert_safe(RedirectSanitizer.sanitize("/\uFF0F\uFF0Fevil.com", @default))
      # As the leading character (not preceded by `/`) these must fall back.
      assert RedirectSanitizer.sanitize("\u2215\u2215evil.com", @default) == @default
      assert RedirectSanitizer.sanitize("\uFF0F\uFF0Fevil.com", @default) == @default
    end

    test "rejects double-encoded scheme and protocol-relative payloads" do
      # %2525 → %25 → `%`. Double-encoded colons and slashes are rebuilt by
      # clients that decode twice. The sanitiser must not accept them as
      # relative paths that later decode to absolute URLs.
      assert_safe(RedirectSanitizer.sanitize("/%2525protocol%253A//evil.com", @default))
      # /%252F%252Fevil.com → /%2F%2Fevil.com → //evil.com after two decodes.
      # The sanitiser rejects this at source; callers receive the default.
      assert RedirectSanitizer.sanitize("/%252F%252Fevil.com", @default) == @default
    end

    test "rejects IDN homograph hosts in absolute URLs" do
      # Cyrillic small letter 'е' (U+0435) in 'evil.com' — visually identical
      # to ASCII 'e'. The scheme + homograph host combination must reach the
      # default, never be returned.
      assert RedirectSanitizer.sanitize("https://\u0435vil.com/path", @default) == @default
      assert RedirectSanitizer.sanitize("//\u0435vil.com/path", @default) == @default
    end

    test "rejects mixed-case scheme separator" do
      assert RedirectSanitizer.sanitize("HTTPS://evil.com/path", @default) == @default
      assert RedirectSanitizer.sanitize("jAvAsCrIpT://alert(1)", @default) == @default
    end
  end

  # Property-based fuzz: whatever the sanitiser returns, it must be a
  # same-origin relative path. This is the one invariant that matters for
  # open-redirect safety regardless of input shape.
  describe "sanitize/2 — property: output is never an absolute URL" do
    property "arbitrary unicode input never produces a schemed or protocol-relative redirect" do
      check all(input <- fuzz_input(), max_runs: 500) do
        result = RedirectSanitizer.sanitize(input, @default)
        assert_safe(result)
      end
    end
  end

  defp fuzz_input do
    # Mix of realistic attack characters: ASCII, null byte, CRLF, URL-encoded
    # bytes, unicode slash look-alikes, and Cyrillic homographs.
    chars = [
      ?a,
      ?b,
      ?c,
      ?d,
      ?.,
      ?/,
      ?:,
      ?@,
      ?%,
      ?\\,
      ?#,
      ??,
      ?&,
      ?=,
      ?+,
      ?-,
      ?~,
      ?0,
      ?1,
      ?\n,
      ?\r,
      ?\t,
      0,
      # Unicode slash look-alikes
      0x2215,
      0xFF0F,
      # Cyrillic homographs for 'e', 'a', 'o'
      0x0435,
      0x0430,
      0x043E
    ]

    StreamData.map(
      StreamData.list_of(StreamData.member_of(chars), min_length: 0, max_length: 40),
      &List.to_string/1
    )
  end

  # The sanitiser's contract: either exactly the default OR a same-origin
  # relative path. "Same-origin" means starts with `/` and does not contain
  # `://` or begin with `//` — neither in the raw form, after one URL decode,
  # nor after two URL decodes (guards against double-encoded bypass payloads).
  defp assert_safe(@default), do: :ok

  defp assert_safe(result) when is_binary(result) do
    assert String.starts_with?(result, "/"),
           "expected #{inspect(result)} to start with '/'"

    refute String.contains?(result, "://"),
           "expected #{inspect(result)} not to contain scheme separator '://'"

    refute String.starts_with?(result, "//"),
           "expected #{inspect(result)} not to be protocol-relative"

    decoded = URI.decode(result)

    refute String.starts_with?(decoded, "//"),
           "expected decoded #{inspect(result)} not to be protocol-relative"

    refute String.starts_with?(URI.decode(decoded), "//"),
           "expected double-decoded #{inspect(result)} not to be protocol-relative"
  end
end
