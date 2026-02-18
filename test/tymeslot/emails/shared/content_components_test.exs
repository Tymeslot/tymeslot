defmodule Tymeslot.Emails.Shared.ContentComponentsTest do
  @moduletag :emails
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Emails.Shared.ContentComponents

  describe "contact_details_card/3" do
  @moduletag :emails
    test "sanitizes row values by default" do
      rows = [
        %{label: "Name", value: "<script>alert('xss')</script>John"},
        %{label: "Email", value: "user@example.com"}
      ]

      html = ContentComponents.contact_details_card("Contact Info", "test@example.com", rows)

      # Script tag should be escaped
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
      # Regular email should still be present
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

      html = ContentComponents.contact_details_card("Contact Info", "test@example.com", rows)

      # Link HTML should be present
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

      html = ContentComponents.contact_details_card("Contact Info", "test@example.com", rows)

      # Link HTML should be present
      assert html =~ "<a href=\"mailto:test@example.com\">"
    end

    test "sanitizes labels" do
      rows = [
        %{label: "<img src=x onerror=alert(1)>", value: "Safe Value"}
      ]

      html = ContentComponents.contact_details_card("Contact Info", "test@example.com", rows)

      # Label should be sanitized
      refute html =~ "<img src=x"
      assert html =~ "&lt;img"
    end

    test "sanitizes title" do
      rows = [%{label: "Test", value: "Value"}]

      html =
        ContentComponents.contact_details_card("<script>Title</script>", "test@example.com", rows)

      refute html =~ "<script>Title</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "message_content_card/2" do
    test "sanitizes message content" do
      html =
        ContentComponents.message_content_card("Message", "<script>alert('xss')</script>Hello")

      refute html =~ "<script>"
      # UniversalSanitizer strips tags rather than escaping them
      refute html =~ "&lt;script&gt;"
      assert html =~ "alert('xss')Hello"
    end

    test "preserves line breaks" do
      html = ContentComponents.message_content_card("Message", "Line 1\nLine 2")

      assert html =~ "<br>"
      assert html =~ "Line 1"
      assert html =~ "Line 2"
    end

    test "sanitizes title" do
      html = ContentComponents.message_content_card("<script>Title</script>", "Safe message")

      refute html =~ "<script>Title</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
