defmodule Tymeslot.Emails.Shared.TextTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Text

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
end
