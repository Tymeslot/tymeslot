defmodule Tymeslot.Security.UrlValidationTest do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.UrlValidation

  @invalid_url_message "Must be a valid HTTP or HTTPS URL (e.g., https://example.com)"
  @missing_scheme_message "Enter a full address starting with https://, for example https://example.com"

  describe "validate_http_url/2" do
    test "accepts valid http and https URLs" do
      assert :ok = UrlValidation.validate_http_url("https://example.com")
      assert :ok = UrlValidation.validate_http_url("http://example.com/path?x=1")
    end

    test "rejects non-binary input" do
      assert UrlValidation.validate_http_url(nil) == {:error, @invalid_url_message}
    end

    test "rejects missing host or malformed URLs" do
      assert UrlValidation.validate_http_url("https://") == {:error, @invalid_url_message}
      assert UrlValidation.validate_http_url("https:///path") == {:error, @invalid_url_message}
    end

    test "rejects unsupported schemes by naming the correction" do
      assert {:error, @missing_scheme_message} =
               UrlValidation.validate_http_url("ftp://example.com")

      assert {:error, @missing_scheme_message} =
               UrlValidation.validate_http_url("javascript:alert(1)")
    end

    test "tells someone who typed a bare host how to write the address" do
      assert {:error, @missing_scheme_message} =
               UrlValidation.validate_http_url("cloud.example.com")
    end

    test "keeps the scheme rule for a disallowed protocol nested in an https URL" do
      # "Start the address with https://" would be nonsense here: it already
      # does. What is wrong is the `javascript:` inside it.
      assert {:error, "Only HTTP and HTTPS URLs are allowed"} =
               UrlValidation.validate_http_url("https://example.com/?next=javascript:alert(1)")
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
