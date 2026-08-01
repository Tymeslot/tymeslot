defmodule Tymeslot.Emails.Shared.TextTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Text

  describe "centered_text/2 and centered_html/2" do
    test "centered_text/2 escapes its input" do
      html = Text.centered_text("O'Brien & Sons")

      assert html =~ "O&#39;Brien &amp; Sons"
    end

    test "centered_html/2 leaves already-escaped content alone" do
      html = Text.centered_html("O&#39;Brien &amp; Sons")

      assert html =~ "O&#39;Brien &amp; Sons"
      refute html =~ "&amp;#39;"
      refute html =~ "&amp;amp;"
    end

    test "both render the same section markup" do
      assert Text.centered_text("Plain") == Text.centered_html("Plain")
    end
  end

  describe "troubleshooting_link/1" do
    test "sanitizes URL for safe display" do
      malicious_url = "https://example.com/<script>alert('xss')</script>"
      html = Text.troubleshooting_link(malicious_url)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "validates http/https scheme" do
      valid_url = "https://example.com/reset/token"
      html = Text.troubleshooting_link(valid_url)

      assert html =~ valid_url
      assert html =~ "href=\"https://example.com/reset/token\""
    end

    test "handles URLs with special characters" do
      url_with_quotes = "https://example.com/reset?token='test'"
      html = Text.troubleshooting_link(url_with_quotes)

      assert html =~ "example.com"
      refute html =~ "'test'"
    end

    test "includes helpful text" do
      html = Text.troubleshooting_link("https://example.com/link")

      assert html =~ "Having trouble with the button"
      assert html =~ "Copy and paste this link"
    end
  end

  describe "bullet_list/1" do
    test "sanitises items to prevent XSS" do
      html = Text.bullet_list(["<script>alert(1)</script>"])

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "renders each item prefixed with a bullet" do
      html = Text.bullet_list(["First item", "Second item"])

      assert html =~ "• First item"
      assert html =~ "• Second item"
    end
  end

  describe "title_section/2 icon option" do
    test "renders an mj-image when a valid https icon URL is provided" do
      html = Text.title_section("Hello", icon: "https://cdn.example.com/icon.png")

      assert html =~ "mj-image"
      assert html =~ "https://cdn.example.com/icon.png"
    end

    test "drops the icon when the URL uses a disallowed scheme" do
      html = Text.title_section("Hello", icon: "javascript:alert(1)")

      refute html =~ "mj-image"
      refute html =~ "javascript:"
    end

    test "drops the icon when the URL is malformed" do
      html = Text.title_section("Hello", icon: "not a url")

      refute html =~ "mj-image"
    end

    test "renders nothing icon-related when the option is omitted" do
      html = Text.title_section("Hello")

      refute html =~ "mj-image"
    end
  end
end
