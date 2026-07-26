defmodule Tymeslot.Emails.Templates.EmailChangeVerificationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.EmailChangeVerification

  import Tymeslot.EmailTestHelpers

  describe "EmailChangeVerification.render/3" do
    test "generates valid HTML output" do
      user = build_user_data(%{name: "Carol White", email: "carol@example.com"})
      new_email = "carol.new@example.com"
      verification_url = "https://example.com/verify-email-change/token123"

      html = EmailChangeVerification.render(user, new_email, verification_url)

      assert String.starts_with?(html, "<!doctype html>")
      assert html =~ "Hi Carol White"
      assert html =~ "Confirm your new email"
    end

    test "includes user name in greeting" do
      user = build_user_data(%{name: "David Brown", email: "david@example.com"})
      new_email = "david.new@example.com"
      verification_url = "https://example.com/verify-email-change/token456"

      html = EmailChangeVerification.render(user, new_email, verification_url)

      assert html =~ "David Brown"
    end

    test "includes new email address" do
      user = build_user_data()
      new_email = "newemail@example.com"
      verification_url = "https://example.com/verify-email-change/token"

      html = EmailChangeVerification.render(user, new_email, verification_url)

      assert html =~ new_email
    end

    test "includes verification URL" do
      user = build_user_data()
      new_email = "new@example.com"
      verification_url = "https://example.com/verify-email-change/unique-token"

      html = EmailChangeVerification.render(user, new_email, verification_url)

      assert html =~ verification_url
    end

    test "includes verification action button" do
      user = build_user_data()
      new_email = "new@example.com"
      verification_url = "https://example.com/verify-email-change/token"

      html = EmailChangeVerification.render(user, new_email, verification_url)

      assert html =~ "Verify New Email"
      assert html =~ verification_url
    end

    test "includes security notice about ignoring if unauthorized" do
      user = build_user_data()
      new_email = "new@example.com"
      verification_url = "https://example.com/verify-email-change/token"

      html = EmailChangeVerification.render(user, new_email, verification_url)

      assert html =~ "You can safely ignore this email"
    end
  end

  describe "EmailChangeVerification.render_text/3" do
    test "returns plain text with user name, new email, and URL" do
      user = build_user_data(%{name: "Carol White", email: "carol@example.com"})
      new_email = "carol.new@example.com"
      verification_url = "https://example.com/verify-email-change/token123"

      text = EmailChangeVerification.render_text(user, new_email, verification_url)

      assert text =~ "Carol White"
      assert text =~ new_email
      assert text =~ verification_url
      assert text =~ "24 hours"
    end
  end

  describe "template security and sanitization" do
    test "EmailChangeVerification handles special characters in email" do
      user = build_user_data()
      new_email = "user+test@example.com"
      verification_url = "https://example.com/verify/token"

      html = EmailChangeVerification.render(user, new_email, verification_url)

      assert html =~ new_email
      assert html =~ verification_url
    end
  end

  describe "render_text security" do
    # Plain-text email bodies are not rendered as HTML, so tags are harmless literal
    # characters. The security properties that matter are: the function never crashes
    # on adversarial input, the verification/reset URL is always present and intact,
    # and injection in one field does not displace other expected content.

    test "EmailChangeVerification.render_text returns a valid binary and preserves URL with malicious name" do
      user = build_user_data(%{name: "<b>Bold</b>", email: "test@example.com"})
      url = "https://example.com/verify/token"
      text = EmailChangeVerification.render_text(user, "new@example.com", url)

      # Plain text is not HTML: the tags survive as literal characters without
      # displacing the verification URL.
      assert text =~ "<b>Bold</b>"
      assert text =~ url
    end
  end
end
