defmodule Tymeslot.Emails.Shared.UiComponentsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.UiComponents

  describe "troubleshooting_link/1" do
    test "sanitizes URL for safe display" do
      malicious_url = "https://example.com/<script>alert('xss')</script>"
      html = UiComponents.troubleshooting_link(malicious_url)

      # Script tag should be escaped in both href and text
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "validates http/https scheme" do
      valid_url = "https://example.com/reset/token"
      html = UiComponents.troubleshooting_link(valid_url)

      assert html =~ valid_url
      assert html =~ "href=\"https://example.com/reset/token\""
    end

    test "handles URLs with special characters" do
      url_with_quotes = "https://example.com/reset?token='test'"
      html = UiComponents.troubleshooting_link(url_with_quotes)

      # Should be sanitized but still functional
      assert html =~ "example.com"
      refute html =~ "'test'"
    end

    test "includes helpful text" do
      html = UiComponents.troubleshooting_link("https://example.com/link")

      assert html =~ "Having trouble with the button"
      assert html =~ "Copy and paste this link"
    end
  end

  describe "quick_info_grid/1" do
    test "sanitizes item labels" do
      items = [
        %{label: "<script>XSS</script>Label", value: "Value 1"},
        %{label: "Label 2", value: "Value 2"}
      ]

      html = UiComponents.quick_info_grid(items)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "Value 1"
      assert html =~ "Value 2"
    end

    test "sanitizes item values" do
      items = [
        %{label: "Duration", value: "<img src=x onerror=alert(1)>30 min"},
        %{label: "Location", value: "Virtual"}
      ]

      html = UiComponents.quick_info_grid(items)

      refute html =~ "<img src=x"
      assert html =~ "30 min"
      assert html =~ "Virtual"
    end

    test "handles empty list gracefully" do
      assert UiComponents.quick_info_grid([]) == ""
    end
  end
end
