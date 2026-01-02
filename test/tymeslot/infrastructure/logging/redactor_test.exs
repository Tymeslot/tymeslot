defmodule Tymeslot.Infrastructure.Logging.RedactorTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Infrastructure.Logging.Redactor

  describe "redact/1" do
    test "redacts Bearer tokens" do
      text = "Authorization: Bearer abcd-1234-efgh-5678"
      assert Redactor.redact(text) == "Authorization: Bearer [REDACTED]"
    end

    test "redacts access tokens in strings" do
      text = "Received access_token: \"secret-token-123\""
      assert Redactor.redact(text) == "Received access_token: \"[REDACTED]\""
    end

    test "redacts refresh tokens" do
      text = "Stored refresh_token: \"refresh-123456\""
      assert Redactor.redact(text) == "Stored refresh_token: \"[REDACTED]\""
    end

    test "redacts API keys" do
      text = "Configured api_key: \"mirotalk-api-key-xyz\""
      assert Redactor.redact(text) == "Configured api_key: \"[REDACTED]\""
    end

    test "redacts multiple sensitive items" do
      text = "Bearer token123 with api_key: \"key456\""
      result = Redactor.redact(text)
      assert result == "Bearer [REDACTED] with api_key: \"[REDACTED]\""
    end

    test "redacts inspected terms" do
      map = %{
        access_token: "secret",
        other: "public"
      }
      result = Redactor.redact(map)
      assert String.contains?(result, "access_token: \"[REDACTED]\"")
      assert String.contains?(result, "other: \"public\"")
    end

    test "redacts complex nested inspected structures" do
      error_tuple = {:error, :unauthorized, "Invalid token: Bearer ya29.a0AfH6SM..."}
      result = Redactor.redact(error_tuple)
      assert result =~ "Bearer [REDACTED]"
      refute result =~ "ya29.a0AfH6SM"
    end

    test "redacts client_secret in strings" do
      text = "config: [client_id: \"abc\", client_secret: \"super-secret-123\"]"
      assert Redactor.redact(text) =~ "client_secret: \"[REDACTED]\""
    end

    test "redacts Basic auth tokens" do
      text = "Authorization: Basic YWxhZGRpbjpvcGVuc2VzYW1l"
      assert Redactor.redact(text) == "Authorization: Basic [REDACTED]"
    end

    test "redacts query parameters" do
      assert Redactor.redact("https://example.com?token=abc-123&other=val") ==
               "https://example.com?token=[REDACTED]&other=val"

      assert Redactor.redact("https://example.com?code=xyz&other=val") ==
               "https://example.com?code=[REDACTED]&other=val"

      assert Redactor.redact("https://example.com?state=secret&other=val") ==
               "https://example.com?state=[REDACTED]&other=val"

      assert Redactor.redact("url?first=1&token=abc") == "url?first=1&token=[REDACTED]"
    end

    test "redacts api_key in different formats" do
      assert Redactor.redact("api_key:\"key123\"") =~ "api_key: \"[REDACTED]\""
      assert Redactor.redact("api_key : \"key456\"") =~ "api_key: \"[REDACTED]\""
    end
  end

  describe "redact_and_truncate/2" do
    test "redacts and truncates a long string" do
      # Put sensitive info early so it survives truncation
      long_text = "access_token: \"secret\", then some very long content: #{String.duplicate("a", 3000)}"
      result = Redactor.redact_and_truncate(long_text, 100)

      assert String.contains?(result, "access_token: \"[REDACTED]\"")
      assert result =~ "[TRUNCATED]"
    end

    test "does not truncate if within limit" do
      text = "access_token: \"secret\""
      result = Redactor.redact_and_truncate(text, 100)
      assert result == "access_token: \"[REDACTED]\""
      refute result =~ "[TRUNCATED]"
    end

    test "handles multi-byte UTF-8 characters correctly during truncation" do
      # Emoji 🚀 is 4 bytes: 0xF0 0x9F 0x9A 0x80
      # If we truncate at 1, 2, or 3 bytes into the emoji, it's invalid UTF-8.
      text = "ABC" <> "🚀🚀🚀"

      # Cut in middle of first emoji (index 4)
      result = Redactor.redact_and_truncate(text, 4)
      assert String.valid?(result)
      assert String.starts_with?(result, "ABC")
      assert result =~ "[TRUNCATED]"

      # Cut in middle of second emoji
      result = Redactor.redact_and_truncate(text, 8)
      assert String.valid?(result)
      assert result =~ "ABC🚀"
      assert result =~ "[TRUNCATED]"
    end
  end
end
