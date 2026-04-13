defmodule Tymeslot.Emails.Shared.CardsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Cards

  describe "quick_info_grid/1" do
    test "sanitizes item labels" do
      items = [
        %{label: "<script>XSS</script>Label", value: "Value 1"},
        %{label: "Label 2", value: "Value 2"}
      ]

      html = Cards.quick_info_grid(items)

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

      html = Cards.quick_info_grid(items)

      refute html =~ "<img src=x"
      assert html =~ "30 min"
      assert html =~ "Virtual"
    end

    test "handles empty list gracefully" do
      assert Cards.quick_info_grid([]) == ""
    end
  end

  describe "contact_details_card/2" do
    test "sanitizes row values by default" do
      rows = [
        %{label: "Name", value: "<script>alert('xss')</script>John"},
        %{label: "Email", value: "user@example.com"}
      ]

      html = Cards.contact_details_card("Contact Info", rows)

      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
      assert html =~ "user@example.com"
    end

    test "allows safe HTML when safe_html flag is set" do
      rows = [
        %{
          label: "Email",
          value: ~s(<a href="mailto:test@example.com">test@example.com</a>),
          safe_html: true
        }
      ]

      html = Cards.contact_details_card("Contact Info", rows)

      assert html =~ "<a href=\"mailto:test@example.com\">"
      assert html =~ "test@example.com"
    end

    test "allows safe HTML via {:safe, html} tuple" do
      rows = [
        %{
          label: "Email",
          value: {:safe, ~s(<a href="mailto:test@example.com">test@example.com</a>)}
        }
      ]

      html = Cards.contact_details_card("Contact Info", rows)

      assert html =~ "<a href=\"mailto:test@example.com\">"
    end

    test "sanitizes labels" do
      rows = [
        %{label: "<img src=x onerror=alert(1)>", value: "Safe Value"}
      ]

      html = Cards.contact_details_card("Contact Info", rows)

      refute html =~ "<img src=x"
      assert html =~ "&lt;img"
    end

    test "sanitizes title" do
      rows = [%{label: "Test", value: "Value"}]

      html = Cards.contact_details_card("<script>Title</script>", rows)

      refute html =~ "<script>Title</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "message_content_card/2" do
    test "sanitizes message content" do
      html = Cards.message_content_card("Message", "<script>alert('xss')</script>Hello")

      refute html =~ "<script>"
      refute html =~ "&lt;script&gt;"
      assert html =~ "alert('xss')Hello"
    end

    test "preserves line breaks" do
      html = Cards.message_content_card("Message", "Line 1\nLine 2")

      assert html =~ "<br>"
      assert html =~ "Line 1"
      assert html =~ "Line 2"
    end

    test "sanitizes title" do
      html = Cards.message_content_card("<script>Title</script>", "Safe message")

      refute html =~ "<script>Title</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
