defmodule Tymeslot.Emails.Templates.NoPasswordToResetTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails
  @moduletag :auth

  alias Tymeslot.Emails.Templates.NoPasswordToReset

  import Tymeslot.EmailTestHelpers

  @sign_in_url "https://example.com/auth/login"

  describe "render/2" do
    test "names the provider the account signs in with and links to sign in" do
      html = NoPasswordToReset.render(build_user_data(%{provider: "google"}), @sign_in_url)

      assert html =~ "<html"
      assert html =~ "signs in with Google, so it has no password to reset"
      assert html =~ ~s(href="#{@sign_in_url}")
    end

    test "carries no password reset link" do
      html = NoPasswordToReset.render(build_user_data(%{provider: "github"}), @sign_in_url)

      refute html =~ "/auth/reset-password"
    end
  end

  describe "render_text/2" do
    test "names GitHub for a GitHub account" do
      text = NoPasswordToReset.render_text(build_user_data(%{provider: "github"}), @sign_in_url)

      assert text =~ "signs in with GitHub"
      assert text =~ @sign_in_url
    end

    test "falls back to single sign-on for a generic provider" do
      text = NoPasswordToReset.render_text(build_user_data(%{provider: "oauth"}), @sign_in_url)

      assert text =~ "signs in with single sign-on"
    end

    test "is translated for the recipient's locale" do
      text =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          NoPasswordToReset.render_text(build_user_data(%{provider: "google"}), @sign_in_url)
        end)

      assert text =~ "meldet sich jedoch über Google an"
    end
  end
end
