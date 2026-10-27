defmodule Tymeslot.Emails.Shared.SanitiseTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Sanitise

  describe "sanitize_multiline_for_email/1" do
    test "returns empty string for nil" do
      assert Sanitise.sanitize_multiline_for_email(nil) == ""
    end

    test "escapes markup and turns both newline styles into line breaks" do
      assert Sanitise.sanitize_multiline_for_email("<b>a</b> -- b\r\nc\nd") ==
               "&lt;b&gt;a&lt;/b&gt; -- b<br>c<br>d"
    end

    test "truncates text longer than 10,000 characters" do
      result = Sanitise.sanitize_multiline_for_email(String.duplicate("a", 10_001))

      assert result == String.duplicate("a", 9_997) <> "..."
    end

    test "keeps text of exactly 10,000 characters whole" do
      text = String.duplicate("a", 10_000)

      assert Sanitise.sanitize_multiline_for_email(text) == text
    end
  end

  describe "sanitize_for_email/1" do
    test "returns empty string for nil" do
      assert Sanitise.sanitize_for_email(nil) == ""
    end

    test "returns trimmed text for clean input" do
      assert Sanitise.sanitize_for_email("Clean text") == "Clean text"
    end

    test "trims whitespace from text" do
      assert Sanitise.sanitize_for_email("  Text with spaces  ") == "Text with spaces"
    end

    test "escapes HTML special characters" do
      text = "<script>alert('XSS')</script>"
      result = Sanitise.sanitize_for_email(text)

      assert result == "&lt;script&gt;alert(&#39;XSS&#39;)&lt;/script&gt;"
      refute result =~ "<script>"
    end

    test "escapes ampersands" do
      text = "Tom & Jerry"
      result = Sanitise.sanitize_for_email(text)

      assert result == "Tom &amp; Jerry"
    end

    test "escapes quotes" do
      text = "He said \"Hello\""
      result = Sanitise.sanitize_for_email(text)

      assert result == "He said &quot;Hello&quot;"
    end

    test "handles combination of trim and escape" do
      text = "  <b>Bold text</b>  "
      result = Sanitise.sanitize_for_email(text)

      assert result == "&lt;b&gt;Bold text&lt;/b&gt;"
      refute result =~ "  "
    end

    test "handles already safe text" do
      text = "Regular text without special chars"
      result = Sanitise.sanitize_for_email(text)

      assert result == text
    end

    test "handles empty string" do
      assert Sanitise.sanitize_for_email("") == ""
    end
  end

  describe "sanitize_url/1" do
    test "escapes a safe http(s) or mailto URL for an href" do
      assert Sanitise.sanitize_url("https://example.com/a?b=1&c=2") ==
               "https://example.com/a?b=1&amp;c=2"

      assert Sanitise.sanitize_url("mailto:someone@example.com") == "mailto:someone@example.com"
    end

    test "is nil for an unsafe, empty or missing URL" do
      assert Sanitise.sanitize_url("javascript:alert(1)") == nil
      assert Sanitise.sanitize_url("#") == nil
      assert Sanitise.sanitize_url("mailto:") == nil
      assert Sanitise.sanitize_url("") == nil
      assert Sanitise.sanitize_url(nil) == nil
    end
  end

  describe "safe_url?/1" do
    test "accepts http(s) and mailto, whatever the scheme's case" do
      for url <- [
            "https://example.com/a",
            "http://example.com",
            "HTTPS://Example.com/a",
            "HtTpS://example.com",
            "mailto:someone@example.com",
            "MailTo:someone@example.com"
          ] do
        assert Sanitise.safe_url?(url), url
      end
    end

    test "rejects other schemes, scheme-relative and whitespace-prefixed URLs" do
      for url <- [
            " https://example.com",
            "\thttps://example.com",
            "\nhttps://example.com",
            "data:text/html,<script>alert(1)</script>",
            "vbscript:msgbox(1)",
            "JaVaScRiPt:alert(1)",
            "//evil.example.com/x",
            "mailto:",
            "MAILTO:",
            "#",
            "",
            nil
          ] do
        refute Sanitise.safe_url?(url), inspect(url)
      end
    end
  end

  describe "safe_web_url?/1" do
    test "accepts http(s) only: a join link must open a page" do
      assert Sanitise.safe_web_url?("https://meet.example.com/room")
      assert Sanitise.safe_web_url?("HTTP://meet.example.com/room")
      refute Sanitise.safe_web_url?("mailto:someone@example.com")
      refute Sanitise.safe_web_url?("room-1234")
      refute Sanitise.safe_web_url?(nil)
    end

    test "sanitize_web_url/1 escapes a web URL and is nil for anything else" do
      assert Sanitise.sanitize_web_url("https://example.com/?a=1&b=2") ==
               "https://example.com/?a=1&amp;b=2"

      assert Sanitise.sanitize_web_url("mailto:someone@example.com") == nil
    end
  end

  describe "sanitize_for_header/1" do
    test "returns empty string for nil" do
      assert Sanitise.sanitize_for_header(nil) == ""
    end

    test "leaves clean text unchanged" do
      assert Sanitise.sanitize_for_header("Reminder: Meeting tomorrow") ==
               "Reminder: Meeting tomorrow"
    end

    test "replaces CR and LF with single space to defeat header injection" do
      injected = "Reminder\r\nBcc: attacker@example.com"
      assert Sanitise.sanitize_for_header(injected) == "Reminder Bcc: attacker@example.com"
    end

    test "strips a bare LF as well as CRLF pairs" do
      assert Sanitise.sanitize_for_header("Subject\nLine") == "Subject Line"
      assert Sanitise.sanitize_for_header("Subject\rLine") == "Subject Line"
    end

    test "strips null bytes and other C0 control characters" do
      assert Sanitise.sanitize_for_header("Hello\x00World") == "Hello World"
      assert Sanitise.sanitize_for_header("Tab\there") == "Tab here"
    end

    test "preserves benign punctuation including angle brackets" do
      # The header sanitiser is about control characters only — it must not
      # mangle natural punctuation a user might legitimately put in a title.
      assert Sanitise.sanitize_for_header("Luka <> Paul — sync") ==
               "Luka <> Paul — sync"

      assert Sanitise.sanitize_for_header("Webhook 'Production'") ==
               "Webhook 'Production'"
    end

    test "collapses runs of whitespace introduced by control-char substitution" do
      assert Sanitise.sanitize_for_header("Hello\r\n\r\nWorld") == "Hello World"
    end

    test "trims surrounding whitespace" do
      assert Sanitise.sanitize_for_header("\n  Subject  \n") == "Subject"
    end
  end
end
