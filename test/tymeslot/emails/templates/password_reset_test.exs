defmodule Tymeslot.Emails.Templates.PasswordResetTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.PasswordReset

  import Tymeslot.EmailTestHelpers

  describe "PasswordReset.render/2" do
    test "generates valid HTML output" do
      user = build_user_data(%{name: "Alice Johnson", email: "alice@example.com"})
      reset_url = "https://example.com/reset/token123"

      html = PasswordReset.render(user, reset_url)

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "includes user name in greeting" do
      user = build_user_data(%{name: "Bob Smith", email: "bob@example.com"})
      reset_url = "https://example.com/reset/token456"

      html = PasswordReset.render(user, reset_url)

      assert html =~ "Bob Smith"
    end

    test "uses a neutral greeting when name is nil, never the email address" do
      user = build_user_data(%{name: nil, email: "reset@example.com"})
      reset_url = "https://example.com/reset/token789"

      html = PasswordReset.render(user, reset_url)

      assert html =~ "Hi there,"
      refute html =~ "Hi reset@example.com"
    end

    test "includes reset URL" do
      user = build_user_data()
      reset_url = "https://example.com/reset/unique-reset-token"

      html = PasswordReset.render(user, reset_url)

      assert html =~ reset_url
    end

    test "includes reset password action button" do
      user = build_user_data()
      reset_url = "https://example.com/reset/token"

      html = PasswordReset.render(user, reset_url)

      assert html =~ "Set New Password"
      assert html =~ reset_url
    end

    test "includes expiration notice" do
      user = build_user_data()
      reset_url = "https://example.com/reset/token"

      html = PasswordReset.render(user, reset_url)

      assert html =~ "2 hours" || html =~ "expire"
    end

    test "includes security notice" do
      user = build_user_data()
      reset_url = "https://example.com/reset/token"

      html = PasswordReset.render(user, reset_url)

      # Use a more flexible assertion that handles potential HTML escaping
      assert html =~ "request"
      assert html =~ "security" || html =~ "secure"
    end
  end

  describe "PasswordReset.render_text/2" do
    test "returns plain text with user name and URL" do
      user = build_user_data(%{name: "Alice Johnson", email: "alice@example.com"})
      reset_url = "https://example.com/reset/token123"

      text = PasswordReset.render_text(user, reset_url)

      assert text =~ "Alice Johnson"
      assert text =~ reset_url
      assert text =~ "2 hours"
    end

    test "uses a neutral greeting when name is nil, never the email address" do
      user = build_user_data(%{name: nil, email: "reset@example.com"})
      text = PasswordReset.render_text(user, "https://example.com/reset/token")

      assert text =~ "Hi there,"
      refute text =~ "Hi reset@example.com"
    end
  end

  describe "template security and sanitization" do
    test "PasswordReset handles malicious HTML in user name" do
      user = build_user_data(%{name: "<img src=x onerror=alert(1)>", email: "test@example.com"})
      reset_url = "https://example.com/reset/token"

      html = PasswordReset.render(user, reset_url)

      assert is_binary(html)
      # The malicious img tag should be sanitized
      refute html =~ "<img src=x"
    end
  end

  describe "render_text security" do
    # Plain-text email bodies are not rendered as HTML, so tags are harmless literal
    # characters. The security properties that matter are: the function never crashes
    # on adversarial input, the verification/reset URL is always present and intact,
    # and injection in one field does not displace other expected content.

    test "PasswordReset.render_text returns a valid binary and preserves URL with malicious name" do
      user = build_user_data(%{name: "<img src=x onerror=alert(1)>", email: "test@example.com"})
      url = "https://example.com/reset/token"
      text = PasswordReset.render_text(user, url)

      assert is_binary(text)
      assert text =~ url
    end
  end
end
