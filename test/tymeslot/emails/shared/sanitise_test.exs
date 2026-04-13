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

      assert result =~ "&quot;" or result =~ "&#34;"
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
end
