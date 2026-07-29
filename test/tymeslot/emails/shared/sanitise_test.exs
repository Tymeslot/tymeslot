defmodule Tymeslot.Emails.Shared.SanitiseTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Sanitise

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
