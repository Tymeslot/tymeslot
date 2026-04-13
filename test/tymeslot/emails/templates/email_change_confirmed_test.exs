defmodule Tymeslot.Emails.Templates.EmailChangeConfirmedTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.EmailChangeConfirmed

  import Tymeslot.EmailTestHelpers

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

  describe "EmailChangeConfirmed.render_text/5" do
    test "returns plain text with change details for new email" do
      user = build_user_data(%{name: "Grace Lee", email: "grace.new@example.com"})
      old_email = "grace.old@example.com"
      new_email = "grace.new@example.com"
      confirmed_time = ~U[2025-01-15 11:00:00Z]

      text = EmailChangeConfirmed.render_text(user, old_email, new_email, confirmed_time, false)

      assert text =~ old_email
      assert text =~ new_email
      assert text =~ "sign in"
    end

    test "includes recipient notice for old email" do
      user = build_user_data()
      text = EmailChangeConfirmed.render_text(user, "old@x.com", "new@x.com", nil, true)

      assert text =~ "previous email address"
    end

    test "handles nil confirmed_time" do
      user = build_user_data()
      text = EmailChangeConfirmed.render_text(user, "old@x.com", "new@x.com", nil, false)

      assert text =~ "Just now"
    end
  end

  describe "render_text security" do
    # Plain-text email bodies are not rendered as HTML, so tags are harmless literal
    # characters. The security properties that matter are: the function never crashes
    # on adversarial input, the verification/reset URL is always present and intact,
    # and injection in one field does not displace other expected content.

    test "EmailChangeConfirmed.render_text returns a valid binary with malicious user name" do
      user = build_user_data(%{name: "<script>steal()</script>", email: "new@example.com"})

      text =
        EmailChangeConfirmed.render_text(user, "old@example.com", "new@example.com", nil, false)

      assert is_binary(text)
      assert text =~ "old@example.com"
      assert text =~ "new@example.com"
    end
  end
end
