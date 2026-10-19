defmodule Tymeslot.Emails.Shared.CardsTest do
  # Not async: asserts the absence of a log event, and the capture handler is
  # global.
  use Tymeslot.DataCase, async: false
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Cards
  alias Tymeslot.Test.LogCapture

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
    test "escapes markup in the message" do
      html = Cards.message_content_card("Message", "<script>alert('xss')</script>Hello")

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;Hello"
    end

    test "escapes links and unclosed tag fragments instead of rendering them" do
      html =
        Cards.message_content_card(
          "Message",
          ~s(See <a href="https://x.example">here</a> and <b style=color:red)
        )

      refute html =~ "<a href"
      refute html =~ "<b style"
      assert html =~ "&lt;a href=&quot;https://x.example&quot;&gt;here&lt;/a&gt;"
      assert html =~ "&lt;b style=color:red"
    end

    test "keeps the text after a double dash" do
      html = Cards.message_content_card("Message", "Hello -- the rest of the message")

      assert html =~ "Hello -- the rest of the message"
    end

    test "preserves line breaks" do
      html = Cards.message_content_card("Message", "Line 1\nLine 2")

      assert html =~ "Line 1<br>Line 2"
    end

    test "logs no security event when rendering a message" do
      LogCapture.attach()

      html = Cards.message_content_card("Message", "Path ../docs -- see 0x1F")

      assert html =~ "Path ../docs -- see 0x1F"

      assert Enum.filter(LogCapture.drain(), fn %{msg: msg} ->
               LogCapture.message_text(msg) =~ "Suspicious input"
             end) == []
    end

    test "sanitizes title" do
      html = Cards.message_content_card("<script>Title</script>", "Safe message")

      refute html =~ "<script>Title</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
