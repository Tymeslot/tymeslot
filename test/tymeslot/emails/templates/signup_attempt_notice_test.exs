defmodule Tymeslot.Emails.Templates.SignupAttemptNoticeTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails
  @moduletag :auth

  alias Tymeslot.Emails.Templates.SignupAttemptNotice

  import Tymeslot.EmailTestHelpers

  @sign_in_url "https://example.com/auth/login"
  @reset_url "https://example.com/auth/reset-password"

  describe "render/3" do
    test "links to both sign-in and the reset form" do
      html = SignupAttemptNotice.render(build_user_data(), @sign_in_url, @reset_url)

      assert html =~ "<html"
      assert html =~ "already has an account"
      assert html =~ ~s(href="#{@sign_in_url}")
      assert html =~ ~s(href="#{@reset_url}")
    end

    test "never renders a non-http reset link" do
      html = SignupAttemptNotice.render(build_user_data(), @sign_in_url, "javascript:alert(1)")

      refute html =~ "javascript:"
    end
  end

  describe "render_text/3" do
    test "carries both links" do
      text = SignupAttemptNotice.render_text(build_user_data(), @sign_in_url, @reset_url)

      assert text =~ @sign_in_url
      assert text =~ @reset_url
      assert text =~ "No new account was created"
    end

    test "is translated for the recipient's locale" do
      text =
        Gettext.with_locale(TymeslotWeb.Gettext, "fr", fn ->
          SignupAttemptNotice.render_text(build_user_data(), @sign_in_url, @reset_url)
        end)

      assert text =~ "Vous avez déjà un compte"
    end
  end
end
