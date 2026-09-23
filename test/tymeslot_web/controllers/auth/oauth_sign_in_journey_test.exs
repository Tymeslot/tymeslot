defmodule TymeslotWeb.OAuthSignInJourneyTest do
  @moduledoc """
  Social sign-in driven end to end through the router: the authorise redirect,
  the provider callback, the complete-registration form, and the email
  verification that follows it. Only the provider's HTTP endpoints are
  stubbed (`Tymeslot.Test.OAuthProviderStub`); state, PKCE, user creation and
  sessions are all real.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :auth
  @moduletag :controllers
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Test.OAuthProviderStub

  alias Phoenix.Flash
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.Workers.EmailWorker

  setup :setup_providers

  setup do
    original_legal = Application.get_env(:tymeslot, :enforce_legal_agreements, false)
    Application.put_env(:tymeslot, :enforce_legal_agreements, false)
    on_exit(fn -> Application.put_env(:tymeslot, :enforce_legal_agreements, original_legal) end)
  end

  describe "an email the provider has verified" do
    test "a GitHub primary verified email creates a verified account with a session" do
      stub_github(%{"id" => 5001, "name" => "Ada", "email" => nil}, [
        %{"email" => "old@example.com", "primary" => false, "verified" => true},
        %{"email" => "ada@example.com", "primary" => true, "verified" => true}
      ])

      conn = sign_in(build_conn(), "github")
      assert redirected_to(conn) == "/auth/complete-registration"

      conn = complete(conn)

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :user_token)

      user = Repo.get_by!(UserSchema, github_user_id: "5001")
      assert user.email == "ada@example.com"
      assert user.verified_at
    end

    test "a Google email with verified_email true creates a verified account" do
      stub_google(%{
        "id" => "g-1",
        "email" => "grace@example.com",
        "verified_email" => true,
        "name" => "Grace"
      })

      conn = build_conn() |> sign_in("google") |> complete()

      assert redirected_to(conn) == "/dashboard"
      assert Repo.get_by!(UserSchema, google_user_id: "g-1").verified_at
    end

    test "an SSO email with email_verified true creates a verified account" do
      stub_sso(%{"sub" => "sub-1", "email" => "sso@example.com", "email_verified" => true})

      conn = build_conn() |> sign_in("oauth") |> complete()

      assert redirected_to(conn) == "/dashboard"
      assert Repo.get_by!(UserSchema, provider: "oauth", provider_uid: "sub-1").verified_at
    end
  end

  describe "an email the provider has not verified" do
    test "Google verified_email false asks for an email and leaves the account unverified" do
      stub_google(%{
        "id" => "g-2",
        "email" => "unconfirmed@example.com",
        "verified_email" => false
      })

      conn = build_conn() |> sign_in("google") |> complete("typed@example.com")

      assert redirected_to(conn) == "/auth/verify-email"
      refute get_session(conn, :user_token)

      user = Repo.get_by!(UserSchema, google_user_id: "g-2")
      assert user.email == "typed@example.com"
      assert user.verified_at == nil
    end

    test "SSO email_verified false asks for an email and leaves the account unverified" do
      stub_sso(%{"sub" => "sub-2", "email" => "sso2@example.com", "email_verified" => false})

      conn = build_conn() |> sign_in("oauth") |> complete("sso2@example.com")

      assert redirected_to(conn) == "/auth/verify-email"
      refute get_session(conn, :user_token)
      assert Repo.get_by!(UserSchema, provider_uid: "sub-2").verified_at == nil
    end

    test "a GitHub email outside the verified list is not trusted" do
      stub_github(%{"id" => 5002, "email" => "public@example.com"}, [
        %{"email" => "public@example.com", "primary" => true, "verified" => false}
      ])

      conn = build_conn() |> sign_in("github") |> complete("public@example.com")

      assert redirected_to(conn) == "/auth/verify-email"
      assert Repo.get_by!(UserSchema, github_user_id: "5002").verified_at == nil
    end
  end

  describe "a typed email" do
    test "is verified by email before the account gets a session" do
      stub_github(%{"id" => 6001, "email" => nil, "name" => "Squatter?"}, [])

      conn = sign_in(build_conn(), "github")
      assert redirected_to(conn) == "/auth/complete-registration"

      conn = complete(conn, "typed@example.com")

      # No session: the address is unproven.
      assert redirected_to(conn) == "/auth/verify-email"
      refute get_session(conn, :user_token)
      assert Flash.get(conn.assigns.flash, :info) =~ "check your email"

      user = Repo.get_by!(UserSchema, github_user_id: "6001")
      assert user.verified_at == nil

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_email_verification", "user_id" => user.id}
      )

      assert conn |> recycle() |> get(~p"/dashboard") |> redirected_to() =~ "/auth/login"

      # Following the emailed link verifies the address.
      token = verification_token(user)
      post(build_conn(), ~p"/auth/verify-complete/#{token}")
      assert Repo.reload!(user).verified_at

      # From then on, signing in with GitHub opens a session.
      login = sign_in(build_conn(), "github")
      assert redirected_to(login) == "/dashboard"
      assert get_session(login, :user_token)
    end

    test "an existing unverified account gets the verify screen, not a session" do
      stub_github(%{"id" => 6002, "email" => nil}, [])
      build_conn() |> sign_in("github") |> complete("later@example.com")
      user = Repo.get_by!(UserSchema, github_user_id: "6002")
      Repo.delete_all(Oban.Job)

      login = sign_in(build_conn(), "github")

      assert redirected_to(login) == "/auth/verify-email"
      refute get_session(login, :user_token)
      # The verify screen can offer to resend for this account.
      assert get_session(login, :unverified_user_id) == user.id

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_email_verification", "user_id" => user.id}
      )
    end
  end

  describe "PKCE" do
    test "the token exchange proves possession of the verifier behind the challenge" do
      stub_github(%{"id" => 7001, "email" => nil}, [])

      start = get(build_conn(), ~p"/auth/github")
      params = start |> redirected_to(302) |> authorise_params()

      assert params["code_challenge_method"] == "S256"
      assert params["code_challenge"] =~ ~r/^[A-Za-z0-9_-]{43}$/

      start
      |> recycle()
      |> get(~p"/auth/github/callback", %{"code" => "c", "state" => params["state"]})

      assert_received {:provider_request, "POST", "/login/oauth/access_token", token_params,
                       "Basic " <> _client_credentials}

      verifier = token_params["code_verifier"]
      assert verifier =~ ~r/^[A-Za-z0-9_-]{43}$/

      assert Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) ==
               params["code_challenge"]
    end
  end

  describe "the pending registration" do
    test "expires after 15 minutes" do
      stub_github(%{"id" => 8001, "email" => nil}, [])
      conn = sign_in(build_conn(), "github")

      ClockHelpers.freeze_clock(DateTime.add(DateTime.utc_now(), 16, :minute))
      conn = complete(conn, "late@example.com")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "expired"
      refute Repo.get_by(UserSchema, github_user_id: "8001")
    end

    test "is refused once the provider has been switched off" do
      stub_github(%{"id" => 8002, "email" => nil}, [])
      conn = sign_in(build_conn(), "github")

      social_auth = Application.get_env(:tymeslot, :social_auth)

      Application.put_env(
        :tymeslot,
        :social_auth,
        Keyword.put(social_auth, :github_enabled, false)
      )

      conn = complete(conn, "off@example.com")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "GitHub authentication is not available"
      refute Repo.get_by(UserSchema, github_user_id: "8002")
    end

    test "submitted twice signs the same account in both times" do
      stub_github(%{"id" => 8003, "email" => nil}, [
        %{"email" => "twice@example.com", "primary" => true, "verified" => true}
      ])

      form = sign_in(build_conn(), "github")

      first = complete(form)
      second = complete(form)

      assert redirected_to(first) == "/dashboard"
      assert redirected_to(second) == "/dashboard"
      assert get_session(second, :user_token)
      assert Repo.aggregate(UserSchema, :count) == 1

      # The second submission signed in; it did not sign anyone up.
      assert Flash.get(second.assigns.flash, :info) == "Successfully signed in with GitHub."
    end

    test "submitted twice with a typed email asks to verify both times, welcoming once" do
      stub_github(%{"id" => 8004, "email" => nil}, [])

      form = sign_in(build_conn(), "github")

      first = complete(form, "twice-typed@example.com")
      second = complete(form, "twice-typed@example.com")

      assert redirected_to(first) == "/auth/verify-email"
      assert redirected_to(second) == "/auth/verify-email"
      refute get_session(second, :user_token)
      assert Flash.get(first.assigns.flash, :info) =~ "successfully signed up"
      refute Flash.get(second.assigns.flash, :info) =~ "signed up"
      assert Repo.aggregate(UserSchema, :count) == 1
    end
  end

  # Posts the complete-registration form from the conn the callback left.
  defp complete(conn, email \\ nil) do
    auth = if email, do: %{"email" => email}, else: %{}

    conn
    |> recycle()
    |> post(~p"/auth/complete", %{"auth" => auth, "profile" => %{"full_name" => "Test User"}})
  end

  defp verification_token(user) do
    [%{args: %{"verification_url" => url}}] =
      Enum.filter(all_enqueued(worker: EmailWorker), &(&1.args["user_id"] == user.id))

    url |> URI.parse() |> Map.fetch!(:path) |> Path.basename()
  end
end
