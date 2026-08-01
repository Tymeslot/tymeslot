defmodule Tymeslot.Emails.Templates.EmailChangeNotificationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.EmailChangeNotification

  import Tymeslot.EmailTestHelpers

  describe "EmailChangeNotification.render/3" do
    test "generates valid HTML output" do
      user = build_user_data(%{name: "Eve Davis", email: "eve@example.com"})
      new_email = "eve.new@example.com"
      request_time = ~U[2025-01-15 10:30:00Z]

      html = EmailChangeNotification.render(user, new_email, request_time)

      assert html =~ "<html"
      assert html =~ "</html>"
      assert html =~ "Email change requested"
    end

    test "includes user name in greeting" do
      user = build_user_data(%{name: "Frank Miller", email: "frank@example.com"})
      new_email = "frank.new@example.com"
      request_time = ~U[2025-01-15 10:30:00Z]

      html = EmailChangeNotification.render(user, new_email, request_time)

      assert html =~ "Frank Miller"
    end

    test "includes new email address" do
      user = build_user_data()
      new_email = "requested-email@example.com"
      request_time = ~U[2025-01-15 10:30:00Z]

      html = EmailChangeNotification.render(user, new_email, request_time)

      assert html =~ new_email
    end

    test "includes current email address" do
      user = build_user_data(%{email: "current@example.com"})
      new_email = "new@example.com"
      request_time = ~U[2025-01-15 10:30:00Z]

      html = EmailChangeNotification.render(user, new_email, request_time)

      assert html =~ "current@example.com"
    end

    test "handles nil request_time" do
      user = build_user_data()
      new_email = "new@example.com"
      request_time = nil

      html = EmailChangeNotification.render(user, new_email, request_time)

      assert html =~ "Just now"
    end

    test "formats request_time when provided" do
      user = build_user_data()
      new_email = "new@example.com"
      request_time = ~U[2025-01-15 10:30:00Z]

      html = EmailChangeNotification.render(user, new_email, request_time)

      assert html =~ "January 15, 2025 at 10:30 AM UTC"
    end

    test "includes security warning about unauthorized access" do
      user = build_user_data()
      new_email = "new@example.com"
      request_time = ~U[2025-01-15 10:30:00Z]

      html = EmailChangeNotification.render(user, new_email, request_time)

      assert html =~ "If you did not request this change"
      assert html =~ "your account may be compromised"
    end
  end

  describe "EmailChangeNotification.render_text/3" do
    test "returns plain text with request details" do
      user = build_user_data(%{name: "Eve Davis", email: "eve@example.com"})
      new_email = "eve.new@example.com"
      request_time = ~U[2025-01-15 10:30:00Z]

      text = EmailChangeNotification.render_text(user, new_email, request_time)

      assert text =~ "Eve Davis"
      assert text =~ new_email
      assert text =~ "eve@example.com"
      assert text =~ "did not request"
    end

    test "handles nil request_time" do
      user = build_user_data()
      text = EmailChangeNotification.render_text(user, "new@example.com", nil)

      assert text =~ "Just now"
    end
  end

  describe "render_text security" do
    # Plain-text email bodies are not rendered as HTML, so tags are harmless literal
    # characters. The security properties that matter are: the function never crashes
    # on adversarial input, the verification/reset URL is always present and intact,
    # and injection in one field does not displace other expected content.

    test "EmailChangeNotification.render_text returns a valid binary with malicious user name" do
      user = build_user_data(%{name: "<script>steal()</script>", email: "test@example.com"})
      text = EmailChangeNotification.render_text(user, "new@example.com", nil)

      assert text =~ "Hi <script>steal()</script>,"
      assert text =~ "new@example.com"
      assert text =~ "test@example.com"
    end
  end
end
