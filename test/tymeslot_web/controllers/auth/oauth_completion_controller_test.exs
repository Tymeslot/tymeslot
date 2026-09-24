defmodule TymeslotWeb.OAuthCompletionControllerTest do
  @moduledoc """
  `POST /auth/complete` against a real pending registration: the entry a
  provider callback leaves in the session. The full journey through the
  provider is in `TymeslotWeb.OAuthSignInJourneyTest`; this file covers the
  form's own rules.
  """

  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :controllers

  import Tymeslot.Factory, only: [insert: 2]
  import Tymeslot.Test.OAuthProviderStub, only: [setup_providers: 1]

  alias Phoenix.Flash
  alias Plug.Test
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.EmailWorker

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

    test "reports a display name too long to store and creates no account", %{conn: conn} do
      conn =
        conn
        |> Test.init_test_session(%{pending_oauth_registration: pending()})
        |> post(~p"/auth/complete", %{"profile" => %{"full_name" => String.duplicate("a", 256)}})

      assert redirected_to(conn) == "/auth/complete-registration?error=validation_failed"

      assert Flash.get(conn.assigns.flash, :error) ==
               "Registration failed due to validation errors. Please check your information and try again."

      refute Repo.get_by(UserSchema, github_user_id: "12345")
    end

    test "fails if no email was typed", %{conn: conn} do
      conn = complete(conn, pending(email: "", email_from_provider: false), %{})

      assert redirected_to(conn) =~ "/auth/complete-registration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Email address is required"
    end

    test "a typed address that is taken is answered like a free one" do
      owner = insert(:user, email: "taken@example.com")

      outcomes =
        for {email, uid} <- [{"fresh@example.com", "111"}, {owner.email, "222"}] do
          conn =
            build_conn()
            |> Test.init_test_session(%{
              pending_oauth_registration:
                pending(email: "", email_from_provider: false, provider_uid: uid)
            })
            |> post(~p"/auth/complete", %{
              "auth" => %{"email" => email},
              "profile" => %{"full_name" => "New User"}
            })

          # The session cookie is signed, not encrypted, so what it carries is
          # visible to the visitor and has to match too.
          session = get_session(conn)

          {redirected_to(conn), conn.assigns.flash,
           Map.take(session, [
             "pending_oauth_registration",
             "unverified_user_id",
             "unverified_user_email"
           ])}
        end

      assert [same, same] = outcomes
      assert {"/auth/verify-email", _flash, %{}} = same

      # Neither got an account: the fresh address was sent a link to finish
      # signing up, and the taken one's owner the sign-up attempt notice.
      refute Repo.get_by(UserSchema, github_user_id: "111")
      refute Repo.get_by(UserSchema, github_user_id: "222")

      assert [_link] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{
                   "action" => "send_social_signup_confirmation",
                   "email" => "fresh@example.com"
                 }
               )

      assert [notice] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{"action" => "send_signup_attempt_notice"}
               )

      assert notice.args["user_id"] == owner.id
    end

    test "the notice to a taken address's owner shares the sign-up form's cap", %{conn: conn} do
      owner = insert(:user, email: "capped@example.com")
      for _i <- 1..5, do: RateLimiter.check_signup_attempt_notice_rate_limit(owner.id)

      conn =
        conn
        |> Test.init_test_session(%{
          pending_oauth_registration: pending(email: "", email_from_provider: false)
        })
        |> post(~p"/auth/complete", %{"auth" => %{"email" => owner.email}})

      assert redirected_to(conn) == "/auth/verify-email"
      assert [] = all_enqueued(worker: EmailWorker)
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
      pending = pending(provider: "oauth", provider_uid: "sub-12345")

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
        provider_uid: "12345",
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
