defmodule Tymeslot.Security.UrlValidationTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Security.UrlValidation

  describe "validate_http_url/2" do
    test "accepts valid http and https URLs" do
      assert :ok = UrlValidation.validate_http_url("https://example.com")
      assert :ok = UrlValidation.validate_http_url("http://example.com/path?x=1")
    end

    test "rejects non-binary input" do
      assert {:error, msg} = UrlValidation.validate_http_url(nil)
      assert is_binary(msg)
    end

    test "rejects missing host or malformed URLs" do
      assert {:error, msg1} = UrlValidation.validate_http_url("https://")
      assert is_binary(msg1)

      assert {:error, msg2} = UrlValidation.validate_http_url("https:///path")
      assert is_binary(msg2)
    end

    test "rejects unsupported schemes with a scheme-specific error" do
      assert {:error, "Only HTTP and HTTPS URLs are allowed"} =
               UrlValidation.validate_http_url("ftp://example.com")

      assert {:error, "Only HTTP and HTTPS URLs are allowed"} =
               UrlValidation.validate_http_url("javascript:alert(1)")
    end

    test "enforces max length when configured" do
      url = "https://example.com/this-is-long"

      assert {:error, "too long"} =
               UrlValidation.validate_http_url(url,
                 max_length: 10,
                 length_error_message: "too long"
               )
    end

    test "blocks configured disallowed protocol substrings" do
      url = "https://example.com/?next=javascript:alert(1)"

      assert {:error, "blocked"} =
               UrlValidation.validate_http_url(url,
                 disallowed_protocols: ["javascript:"],
                 disallowed_protocol_error: "blocked"
               )
    end

    test "can enforce https for non-local hosts" do
      assert {:error, "https required"} =
               UrlValidation.validate_http_url("http://example.com",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://localhost",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://127.0.0.1",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )

      assert :ok =
               UrlValidation.validate_http_url("http://10.0.0.1",
                 enforce_https_for_public: true,
                 https_error_message: "https required"
               )
    end

    test "supports extra checks via a callback" do
      ok_check = fn _context -> :ok end

      assert :ok =
               UrlValidation.validate_http_url("https://example.com",
                 extra_checks: ok_check
               )

      error_check = fn _context -> {:error, "custom rule"} end

      assert {:error, "custom rule"} =
               UrlValidation.validate_http_url("https://example.com",
                 extra_checks: error_check
               )
    end
  end
end
