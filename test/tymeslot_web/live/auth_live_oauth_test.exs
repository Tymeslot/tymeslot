defmodule TymeslotWeb.AuthLiveOAuthTest do
  @moduledoc """
  The sign-in pages' social buttons and the registration an OAuth sign-in
  completes. Async false: the tests switch the social sign-in config.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :auth

  alias Tymeslot.Auth

  describe "social sign-in buttons" do
    test "offer exactly the enabled providers, by display name", %{conn: conn} do
      social_auth = Application.get_env(:tymeslot, :social_auth, [])

      Application.put_env(
        :tymeslot,
        :social_auth,
        Keyword.merge(social_auth,
          google_enabled: false,
          github_enabled: true,
          oauth_enabled: true
        )
      )

      on_exit(fn -> Application.put_env(:tymeslot, :social_auth, social_auth) end)

      {:ok, view, _html} = live(conn, ~p"/auth/login")

      assert has_element?(view, ~s(a.btn-oauth[href="/auth/github"]), "GitHub")
      assert has_element?(view, ~s(a.btn-oauth[href="/auth/oauth"]), "SSO")
      refute has_element?(view, ~s(a.btn-oauth[href="/auth/google"]))
    end

    test "name the SSO provider when its configuration carries a name", %{conn: conn} do
      social_auth = Application.get_env(:tymeslot, :social_auth, [])
      oauth_provider = Application.get_env(:tymeslot, :oauth_provider, [])

      Application.put_env(:tymeslot, :social_auth, Keyword.put(social_auth, :oauth_enabled, true))

      Application.put_env(
        :tymeslot,
        :oauth_provider,
        Keyword.put(oauth_provider, :name, "Beaver Cloud")
      )

      on_exit(fn ->
        Application.put_env(:tymeslot, :social_auth, social_auth)
        Application.put_env(:tymeslot, :oauth_provider, oauth_provider)
      end)

      {:ok, view, _html} = live(conn, ~p"/auth/login")

      assert has_element?(view, ~s(a.btn-oauth[href="/auth/oauth"]), "Beaver Cloud")
      refute has_element?(view, ~s(a.btn-oauth[href="/auth/oauth"]), "SSO")
    end
  end

  describe "OAuth Completion" do
    test "renders complete registration form with session data", %{conn: conn} do
      conn =
        init_test_session(conn, %{
          "pending_oauth_registration" => %{
            provider: "github",
            email: "oauth@example.com",
            name: nil,
            email_from_provider: true,
            provider_uid: "12345",
            github_user_id: "12345",
            google_user_id: nil
          }
        })

      {:ok, view, html} = live(conn, ~p"/auth/complete-registration")

      assert has_element?(view, "#complete-registration-form")
      assert html =~ "oauth@example.com"

      # The display name stays optional, as the server treats it: a blank one
      # completes the registration, so the browser must not demand one.
      assert has_element?(view, "input#full-name")
      refute has_element?(view, "input#full-name[required]")
    end

    test "successful OAuth completion", %{conn: conn} do
      social_auth = Application.get_env(:tymeslot, :social_auth, [])

      Application.put_env(
        :tymeslot,
        :social_auth,
        Keyword.put(social_auth, :github_enabled, true)
      )

      on_exit(fn -> Application.put_env(:tymeslot, :social_auth, social_auth) end)

      conn =
        init_test_session(conn, %{
          "pending_oauth_registration" => %{
            provider: "github",
            email: "oauth_new@example.com",
            name: nil,
            email_from_provider: true,
            provider_uid: "gh_new_123",
            created_at: System.system_time(:second)
          }
        })

      {:ok, view, _html} = live(conn, ~p"/auth/complete-registration")

      form =
        form(view, "#complete-registration-form", %{
          "profile" => %{"full_name" => "OAuth New User"},
          "auth" => %{"terms_accepted" => "true"}
        })

      conn = submit_form(form, conn)
      assert redirected_to(conn) == "/dashboard"

      # Verify user was created
      assert user = Auth.get_user_by_email("oauth_new@example.com")
      assert user.github_user_id == "gh_new_123"
    end
  end
end
