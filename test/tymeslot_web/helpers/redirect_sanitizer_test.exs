defmodule TymeslotWeb.Helpers.RedirectSanitizerTest do
  use ExUnit.Case, async: true
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
end
