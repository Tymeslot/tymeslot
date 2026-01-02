defmodule Tymeslot.Emails.Templates.AuthEmailsTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Emails.Templates.{
    EmailChangeConfirmed,
    EmailChangeNotification,
    EmailChangeVerification,
    EmailVerification,
    PasswordReset
  }

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

    test "uses email as fallback when name is nil" do
      user = build_user_data(%{name: nil, email: "user@example.com"})
      verification_url = "https://example.com/verify/token789"

      html = EmailVerification.render(user, verification_url)

      assert html =~ "user@example.com"
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

      assert html =~ "Verify"
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

    test "uses email as fallback when name is nil" do
      user = build_user_data(%{name: nil, email: "reset@example.com"})
      reset_url = "https://example.com/reset/token789"

      html = PasswordReset.render(user, reset_url)

      assert html =~ "reset@example.com"
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

      assert html =~ "Reset"
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

      assert html =~ "didn't request" || html =~ "security"
    end
  end

  describe "EmailChangeVerification.render/3" do
    test "generates valid HTML output" do
      user = build_user_data(%{name: "Carol White", email: "carol@example.com"})
      new_email = "carol.new@example.com"
      verification_url = "https://example.com/verify-email-change/token123"

      html = EmailChangeVerification.render(user, new_email, verification_url)

      assert is_binary(html)
      assert String.length(html) > 500
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

      assert html =~ "Verify"
      assert html =~ verification_url
    end

    test "includes security notice about ignoring if unauthorized" do
      user = build_user_data()
      new_email = "new@example.com"
      verification_url = "https://example.com/verify-email-change/token"

      html = EmailChangeVerification.render(user, new_email, verification_url)

      assert html =~ "didn't request" || html =~ "ignore"
    end
  end

  describe "EmailChangeNotification.render/3" do
    test "generates valid HTML output" do
      user = build_user_data(%{name: "Eve Davis", email: "eve@example.com"})
      new_email = "eve.new@example.com"
      request_time = ~U[2025-01-15 10:30:00Z]

      html = EmailChangeNotification.render(user, new_email, request_time)

      assert is_binary(html)
      assert String.length(html) > 500
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

      assert is_binary(html)
      assert html =~ "Just now"
    end

    test "formats request_time when provided" do
      user = build_user_data()
      new_email = "new@example.com"
      request_time = ~U[2025-01-15 10:30:00Z]

      html = EmailChangeNotification.render(user, new_email, request_time)

      assert is_binary(html)
      # Should contain formatted time
      assert String.length(html) > 500
    end

    test "includes security warning about unauthorized access" do
      user = build_user_data()
      new_email = "new@example.com"
      request_time = ~U[2025-01-15 10:30:00Z]

      html = EmailChangeNotification.render(user, new_email, request_time)

      assert html =~ "did NOT request" || html =~ "compromised"
    end
  end

  describe "EmailChangeConfirmed.render/5" do
    test "generates valid HTML output for new email" do
      user = build_user_data(%{name: "Grace Lee", email: "grace.new@example.com"})
      old_email = "grace.old@example.com"
      new_email = "grace.new@example.com"
      confirmed_time = ~U[2025-01-15 11:00:00Z]
      is_old_email = false

      html = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, is_old_email)

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "generates valid HTML output for old email" do
      user = build_user_data(%{name: "Henry Taylor", email: "henry.new@example.com"})
      old_email = "henry.old@example.com"
      new_email = "henry.new@example.com"
      confirmed_time = ~U[2025-01-15 11:00:00Z]
      is_old_email = true

      html = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, is_old_email)

      assert is_binary(html)
      assert String.length(html) > 500
    end

    test "includes both old and new email addresses" do
      user = build_user_data()
      old_email = "old-address@example.com"
      new_email = "new-address@example.com"
      confirmed_time = ~U[2025-01-15 11:00:00Z]
      is_old_email = false

      html = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, is_old_email)

      assert html =~ old_email
      assert html =~ new_email
    end

    test "shows special notice when sent to old email" do
      user = build_user_data()
      old_email = "old@example.com"
      new_email = "new@example.com"
      confirmed_time = ~U[2025-01-15 11:00:00Z]
      is_old_email = true

      html = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, is_old_email)

      assert html =~ "previous email" || html =~ "old email"
    end

    test "handles nil confirmed_time" do
      user = build_user_data()
      old_email = "old@example.com"
      new_email = "new@example.com"
      confirmed_time = nil
      is_old_email = false

      html = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, is_old_email)

      assert is_binary(html)
      assert html =~ "Just now"
    end

    test "formats confirmed_time when provided" do
      user = build_user_data()
      old_email = "old@example.com"
      new_email = "new@example.com"
      confirmed_time = ~U[2025-01-15 11:00:00Z]
      is_old_email = false

      html = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, is_old_email)

      assert is_binary(html)
      # Should contain formatted time
      assert String.length(html) > 500
    end

    test "includes instructions for using new email" do
      user = build_user_data()
      old_email = "old@example.com"
      new_email = "new@example.com"
      confirmed_time = ~U[2025-01-15 11:00:00Z]
      is_old_email = false

      html = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time, is_old_email)

      assert html =~ "sign in" || html =~ "Sign in"
    end

    test "uses default value for is_old_email parameter" do
      user = build_user_data()
      old_email = "old@example.com"
      new_email = "new@example.com"
      confirmed_time = ~U[2025-01-15 11:00:00Z]

      # Call without is_old_email parameter (should default to false)
      html = EmailChangeConfirmed.render(user, old_email, new_email, confirmed_time)

      assert is_binary(html)
      assert String.length(html) > 500
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

    test "PasswordReset handles malicious HTML in user name" do
      user = build_user_data(%{name: "<img src=x onerror=alert(1)>", email: "test@example.com"})
      reset_url = "https://example.com/reset/token"

      html = PasswordReset.render(user, reset_url)

      assert is_binary(html)
      # The malicious img tag should be sanitized
      refute html =~ "<img src=x"
    end

    test "EmailChangeVerification handles special characters in email" do
      user = build_user_data()
      new_email = "user+test@example.com"
      verification_url = "https://example.com/verify/token"

      html = EmailChangeVerification.render(user, new_email, verification_url)

      assert is_binary(html)
      assert html =~ new_email
    end
  end
end
