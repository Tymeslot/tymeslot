defmodule Tymeslot.Emails.Shared.ButtonsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Buttons

  describe "action_button/4" do
    test "includes the URL and label in output for a valid https URL" do
      html = Buttons.action_button(:confirmed, "Book Now", "https://example.com/book")

      assert html =~ "https://example.com/book"
      assert html =~ "Book Now"
    end

    test "falls back to href=\"#\" for an invalid URL" do
      html = Buttons.action_button(:confirmed, "Click", "javascript:alert(1)")

      assert html =~ ~s(href="#")
      refute html =~ "javascript:"
    end

    test "passes mailto: URL through unchanged" do
      html = Buttons.action_button(:confirmed, "Email Us", "mailto:support@example.com")

      assert html =~ "mailto:support@example.com"
    end

    test "full_width: true produces a different output than the default" do
      html_full = Buttons.action_button(:confirmed, "Go", "https://example.com", full_width: true)
      html_default = Buttons.action_button(:confirmed, "Go", "https://example.com")

      refute html_full == html_default
      assert html_full =~ "mobile-button"
      refute html_default =~ "mobile-button"
    end
  end

  describe "action_button_group/2" do
    test "includes both button URLs and labels in the output" do
      buttons = [
        %{text: "Accept", url: "https://example.com/accept"},
        %{text: "Decline", url: "https://example.com/decline"}
      ]

      html = Buttons.action_button_group(:confirmed, buttons)

      assert html =~ "https://example.com/accept"
      assert html =~ "Accept"
      assert html =~ "https://example.com/decline"
      assert html =~ "Decline"
    end
  end
end
