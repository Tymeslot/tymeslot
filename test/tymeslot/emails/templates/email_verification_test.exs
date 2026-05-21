defmodule Tymeslot.Emails.Templates.EmailVerificationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.EmailVerification

  import Tymeslot.EmailTestHelpers

  describe "EmailVerification.render/2" do
    test "generates valid HTML output" do
      user = build_user_data(%{name: "John Doe", email: "john@example.com"})
      verification_url = "https://example.com/verify/token123"

      html = EmailVerification.render(user, verification_url)

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "includes user name in greeting" do
      user = build_user_data(%{name: "Jane Smith", email: "jane@example.com"})
      verification_url = "https://example.com/verify/token456"

      html = EmailVerification.render(user, verification_url)

      assert html =~ "Jane Smith"
    end

    test "uses a neutral greeting when name is nil, never the email address" do
      user = build_user_data(%{name: nil, email: "user@example.com"})
      verification_url = "https://example.com/verify/token789"

      html = EmailVerification.render(user, verification_url)

      assert html =~ "Hi there,"
      refute html =~ "Hi user@example.com"
    end

    test "includes verification URL" do
      user = build_user_data()
      verification_url = "https://example.com/verify/unique-token"

      html = EmailVerification.render(user, verification_url)

      assert html =~ verification_url
    end

    test "includes verification action button" do
      user = build_user_data()
      verification_url = "https://example.com/verify/token"

      html = EmailVerification.render(user, verification_url)

      assert html =~ "Confirm Email"
      assert html =~ verification_url
    end

    test "includes expiration notice" do
      user = build_user_data()
      verification_url = "https://example.com/verify/token"

      html = EmailVerification.render(user, verification_url)

      assert html =~ "24 hours" || html =~ "expire"
    end

    test "handles special characters in user name" do
      user = build_user_data(%{name: "O'Brien & Sons", email: "obrien@example.com"})
      verification_url = "https://example.com/verify/token"

      html = EmailVerification.render(user, verification_url)

      assert is_binary(html)
      assert String.length(html) > 500
    end
  end

  describe "EmailVerification.render_text/2" do
    test "returns plain text with user name and URL" do
      user = build_user_data(%{name: "John Doe", email: "john@example.com"})
      verification_url = "https://example.com/verify/token123"

      text = EmailVerification.render_text(user, verification_url)

      assert text =~ "John Doe"
      assert text =~ verification_url
      assert text =~ "24 hours"
    end

    test "uses a neutral greeting when name is nil, never the email address" do
      user = build_user_data(%{name: nil, email: "user@example.com"})
      text = EmailVerification.render_text(user, "https://example.com/verify/token")

      assert text =~ "Hi there,"
      refute text =~ "Hi user@example.com"
    end
  end

  describe "template security and sanitization" do
    test "EmailVerification handles malicious HTML in user name" do
      user = build_user_data(%{name: "<script>alert('xss')</script>", email: "test@example.com"})
      verification_url = "https://example.com/verify/token"

      html = EmailVerification.render(user, verification_url)

      assert is_binary(html)
      # Script tags should be sanitized
      refute html =~ "<script>"
    end
  end

  describe "render_text security" do
    # Plain-text email bodies are not rendered as HTML, so tags are harmless literal
    # characters. The security properties that matter are: the function never crashes
    # on adversarial input, the verification/reset URL is always present and intact,
    # and injection in one field does not displace other expected content.

    test "EmailVerification.render_text returns a valid binary and preserves URL with malicious name" do
      user = build_user_data(%{name: "<script>alert('xss')</script>", email: "test@example.com"})
      url = "https://example.com/verify/token"
      text = EmailVerification.render_text(user, url)

      assert is_binary(text)
      assert text =~ url
    end

    test "EmailVerification.render_text URL is intact even when name contains newlines" do
      user = build_user_data(%{name: "Attacker\n\n", email: "test@example.com"})
      url = "https://example.com/verify/token"
      text = EmailVerification.render_text(user, url)

      assert text =~ url
    end
  end
end
