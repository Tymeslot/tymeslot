defmodule Tymeslot.Emails.Templates.SignupAttemptNoticeTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails
  @moduletag :auth

  alias Tymeslot.Emails.Templates.SignupAttemptNotice

  import Tymeslot.EmailTestHelpers
  import Tymeslot.Factory

  @sign_in_url "https://example.com/auth/login"
  @reset_url "https://example.com/auth/reset-password"

  describe "render/3" do
    test "links to both sign-in and the reset form" do
      html = SignupAttemptNotice.render(build_user_data(), @sign_in_url, @reset_url).html_body

      assert html =~ "<html"
      assert html =~ "already has an account"
      assert html =~ ~s(href="#{@sign_in_url}")
      assert html =~ ~s(href="#{@reset_url}")
    end

    test "never renders a non-http reset link" do
      html =
        SignupAttemptNotice.render(build_user_data(), @sign_in_url, "javascript:alert(1)").html_body

      refute html =~ "javascript:"
    end
  end

  describe "render_text/3" do
    test "carries both links" do
      text = SignupAttemptNotice.render(build_user_data(), @sign_in_url, @reset_url).text_body

      assert text =~ @sign_in_url
      assert text =~ @reset_url
      assert text =~ "No new account was created"
    end

    test "is translated for the recipient's locale" do
      text =
        SignupAttemptNotice.render(build_user_data(%{locale: "fr"}), @sign_in_url, @reset_url).text_body

      assert text =~ "Vous avez déjà un compte"
    end
  end

  describe "for an account that signs in through a provider" do
    test "says to sign in with the provider and offers no password reset" do
      user = build_user_data(%{provider: "google"})

      html = SignupAttemptNotice.render(user, @sign_in_url, @reset_url).html_body
      text = SignupAttemptNotice.render(user, @sign_in_url, @reset_url).text_body

      for body <- [html, text] do
        assert body =~ "sign in with Google"
        refute body =~ @reset_url
        refute body =~ "reset your password"
      end

      assert html =~ ~s(href="#{@sign_in_url}")
    end
  end

  describe "an address whose account is pending deletion" do
    test "names the date as the owner's own calendar day" do
      owner = insert(:user)
      insert(:profile, user: owner, timezone: "Pacific/Kiritimati")

      user = %{
        id: owner.id,
        name: "Ada",
        email: "ada@example.com",
        provider: "email",
        deletion_scheduled_at: ~U[2026-10-16 12:00:00Z]
      }

      text =
        Gettext.with_locale(TymeslotWeb.Gettext, "en", fn ->
          SignupAttemptNotice.render(user, @sign_in_url, @reset_url).text_body
        end)

      assert text =~ "scheduled for deletion on 17 October 2026"
    end

    test "names the deletion date and both ways forward" do
      user = %{
        id: 1,
        name: "Ada",
        email: "ada@example.com",
        provider: "email",
        deletion_scheduled_at: ~U[2026-10-16 09:00:00Z]
      }

      text =
        Gettext.with_locale(TymeslotWeb.Gettext, "en", fn ->
          SignupAttemptNotice.render(user, @sign_in_url, @reset_url).text_body
        end)

      assert text =~ "scheduled for deletion on 16 October 2026"
      assert text =~ "sign up again after that date"
      refute text =~ "which already has an account"
    end
  end
end
