defmodule TymeslotWeb.AuthLiveFeatureFlagsTest do
  @moduledoc """
  Covers the auth LiveView when a self-host deployment switches registration or
  password authentication off.

  These are deployment-configuration paths rather than user journeys: each
  describe flips one application flag and asserts that the routes it closes
  redirect, that the login page stops advertising the closed flow, and that the
  matching `navigate_to` events cannot reopen it from the client. They are kept
  apart from `TymeslotWeb.AuthLiveTest`, which exercises the same LiveView with
  both flags at their defaults.
  """
  use TymeslotWeb.LiveCase, async: false
  @moduletag :auth

  alias Tymeslot.Auth.AuthActions

  describe "Registration disabled" do
    setup do
      original = Application.get_env(:tymeslot, :registration_enabled)
      Application.put_env(:tymeslot, :registration_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :registration_enabled, original) end)
      :ok
    end

    test "redirects /auth/signup to login with flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, ~p"/auth/signup")

      assert flash["info"] =~ AuthActions.registration_disabled_message()
    end

    test "redirects /auth/complete-registration to login with flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, ~p"/auth/complete-registration")

      assert flash["info"] =~ AuthActions.registration_disabled_message()
    end

    test "hides sign up link on login page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/auth/login")
      refute html =~ "Sign up"
    end

    test "blocks navigate_to signup event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")

      render_hook(view, "navigate_to", %{"state" => "signup"})

      assert has_element?(view, "#login-form")
    end
  end

  describe "Password auth disabled" do
    setup do
      original = Application.get_env(:tymeslot, :password_auth_enabled)
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :password_auth_enabled, original) end)
      :ok
    end

    test "redirects /auth/signup to login with flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, ~p"/auth/signup")

      assert flash["info"] =~ AuthActions.password_auth_disabled_message()
    end

    test "redirects /auth/reset-password to login with flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, ~p"/auth/reset-password")

      assert flash["info"] =~ AuthActions.password_auth_disabled_message()
    end

    test "redirects /auth/reset-password?token=... (reset form) to login with flash", %{
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, "/auth/reset-password?token=sometoken")

      assert flash["info"] =~ AuthActions.password_auth_disabled_message()
    end

    test "redirects /auth/reset-password-sent to login with flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, ~p"/auth/reset-password-sent")

      assert flash["info"] =~ AuthActions.password_auth_disabled_message()
    end

    test "login page shows no password form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")

      refute has_element?(view, "#login-form")
      refute render(view) =~ "Forgot password?"
    end

    test "login page hides sign up footer link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/auth/login")

      refute html =~ "Sign up"
    end

    test "blocks navigate_to signup event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")

      render_hook(view, "navigate_to", %{"state" => "signup"})

      refute has_element?(view, "#signup-form")
    end

    test "blocks navigate_to reset_password event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")

      render_hook(view, "navigate_to", %{"state" => "reset_password"})

      refute has_element?(view, "#reset-password-form")
    end

    test "/auth/complete-registration still works", %{conn: conn} do
      conn =
        init_test_session(conn, %{
          "pending_oauth_registration" => %{
            provider: "github",
            email: "oauth@example.com",
            name: nil,
            is_verified: true,
            email_from_provider: true,
            provider_uid: "12345",
            github_user_id: "12345",
            google_user_id: nil
          }
        })

      {:ok, view, _html} = live(conn, ~p"/auth/complete-registration")

      assert has_element?(view, "#complete-registration-form")
    end
  end
end
