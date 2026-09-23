defmodule TymeslotWeb.OAuthCompletionControllerTest do
  @moduledoc """
  `POST /auth/complete` against a real pending registration: the entry a
  provider callback leaves in the session. The full journey through the
  provider is in `TymeslotWeb.OAuthSignInJourneyTest`; this file covers the
  form's own rules.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :auth
  @moduletag :controllers

  import Tymeslot.Factory, only: [insert: 2]
  import Tymeslot.Test.OAuthProviderStub, only: [setup_providers: 1]

  alias Phoenix.Flash
  alias Plug.Test
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo

  # `RateLimiter.OAuth.check_completion/1` allows this many per IP per window.
  @completion_limit 6

  setup :setup_providers

  setup do
    original = Application.get_env(:tymeslot, :enforce_legal_agreements, false)
    Application.put_env(:tymeslot, :enforce_legal_agreements, false)
    on_exit(fn -> Application.put_env(:tymeslot, :enforce_legal_agreements, original) end)
  end

  describe "POST /auth/complete" do
    test "requires terms acceptance when enforced", %{conn: conn} do
      Application.put_env(:tymeslot, :enforce_legal_agreements, true)

      conn = complete(conn, pending(), %{})

      assert redirected_to(conn) =~ "/auth/complete-registration"
      assert Flash.get(conn.assigns.flash, :error) =~ "must accept the terms"
      refute Repo.get_by(UserSchema, github_user_id: "12345")
    end

    test "records accepted terms and creates the account", %{conn: conn} do
      Application.put_env(:tymeslot, :enforce_legal_agreements, true)

      conn = complete(conn, pending(), %{"auth" => %{"terms_accepted" => "on"}})

      assert redirected_to(conn) == "/dashboard"
      assert Repo.get_by(UserSchema, github_user_id: "12345")
    end

    test "fails if no email was typed", %{conn: conn} do
      conn = complete(conn, pending(email: "", email_from_provider: false), %{})

      assert redirected_to(conn) =~ "/auth/complete-registration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Email address is required"
    end

    test "reports a taken email as email_taken in a non-English locale", %{conn: conn} do
      insert(:user, email: "taken@example.com")

      conn =
        conn
        |> Test.init_test_session(%{
          pending_oauth_registration: pending(email: "", email_from_provider: false),
          locale: "de"
        })
        |> post(~p"/auth/complete", %{"auth" => %{"email" => "taken@example.com"}})

      # The reason travels as an atom, so the query parameter does not depend
      # on the language the flash is rendered in.
      assert redirected_to(conn) == "/auth/complete-registration?error=email_taken"

      assert Flash.get(conn.assigns.flash, :error) ==
               "Diese E-Mail-Adresse ist bereits registriert. Bitte verwenden Sie eine andere Adresse."
    end

    test "redirects to login when no session data present", %{conn: conn} do
      conn = post(conn, ~p"/auth/complete", %{})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Missing OAuth provider information"
    end

    test "refuses completions past the per-IP allowance", %{conn: conn} do
      for _attempt <- 1..@completion_limit, do: post(conn, ~p"/auth/complete", %{})

      conn = post(conn, ~p"/auth/complete", %{})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Too many registration attempts"
    end

    test "names the generic provider by its display name", %{conn: conn} do
      pending = pending(provider: "oauth", github_user_id: nil, provider_uid: "sub-12345")

      conn = complete(conn, pending, %{})

      assert redirected_to(conn) == "/dashboard"
      assert Repo.get_by!(UserSchema, provider: "oauth", provider_uid: "sub-12345").verified_at

      assert Flash.get(conn.assigns.flash, :info) ==
               "Welcome! You've successfully signed up with SSO."
    end

    test "clears the pending registration once the account exists", %{conn: conn} do
      conn = complete(conn, pending(), %{})

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :pending_oauth_registration) == nil
    end

    test "clears the session on an unsupported provider", %{conn: conn} do
      conn = complete(conn, pending(provider: "totally_unsupported"), %{})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Unsupported OAuth provider"
      assert get_session(conn, :pending_oauth_registration) == nil
    end

    test "takes a provider-vouched email from the session, never the form", %{conn: conn} do
      conn =
        complete(conn, pending(), %{
          "auth" => %{"provider" => "google", "email" => "attacker@evil.com"}
        })

      assert redirected_to(conn) == "/dashboard"
      assert Repo.get_by!(UserSchema, github_user_id: "12345").email == "new@example.com"
      refute Repo.get_by(UserSchema, email: "attacker@evil.com")
    end

    test "redirects to login with an info flash when registration is disabled", %{conn: conn} do
      original = Application.get_env(:tymeslot, :registration_enabled, true)
      Application.put_env(:tymeslot, :registration_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :registration_enabled, original) end)

      conn = complete(conn, pending(), %{})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Registration is currently disabled"
      refute Repo.get_by(UserSchema, github_user_id: "12345")
    end
  end

  # The entry `FlowHandler` leaves for a GitHub sign-up whose verified email
  # GitHub supplied.
  defp pending(overrides \\ []) do
    Map.merge(
      %{
        provider: "github",
        email: "new@example.com",
        name: "New User",
        email_from_provider: true,
        github_user_id: "12345",
        created_at: System.system_time(:second)
      },
      Map.new(overrides)
    )
  end

  defp complete(conn, pending, params) do
    conn
    |> Test.init_test_session(%{pending_oauth_registration: pending})
    |> post(~p"/auth/complete", Map.put_new(params, "profile", %{"full_name" => "New User"}))
  end
end
