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

  import Tymeslot.Factory, only: [insert: 2]
  import Tymeslot.Test.OAuthProviderStub

  alias Phoenix.Flash
  alias Phoenix.Token
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Emails.EmailScheduler.LinkArg
  alias Tymeslot.Repo
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Endpoint

  # Mirrors `Tymeslot.Auth.OAuth.SignupConfirmation`'s salt, to sign a stale
  # token; the expiry test checks that a fresh token with it is accepted.
  @confirmation_salt "oauth typed-email sign-up confirmation"

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
    test "Google verified_email false asks for an email and creates nothing yet" do
      stub_google(%{
        "id" => "g-2",
        "email" => "unconfirmed@example.com",
        "verified_email" => false
      })

      conn = build_conn() |> sign_in("google") |> complete("typed@example.com")

      assert redirected_to(conn) == "/auth/verify-email"
      refute get_session(conn, :user_token)
      refute Repo.get_by(UserSchema, google_user_id: "g-2")
      assert confirmation_link("typed@example.com")
    end

    test "SSO email_verified false asks for an email and creates nothing yet" do
      stub_sso(%{"sub" => "sub-2", "email" => "sso2@example.com", "email_verified" => false})

      conn = build_conn() |> sign_in("oauth") |> complete("sso2@example.com")

      assert redirected_to(conn) == "/auth/verify-email"
      refute get_session(conn, :user_token)
      refute Repo.get_by(UserSchema, provider_uid: "sub-2")
    end

    test "a GitHub email outside the verified list is not trusted" do
      stub_github(%{"id" => 5002, "email" => "public@example.com"}, [
        %{"email" => "public@example.com", "primary" => true, "verified" => false}
      ])

      conn = build_conn() |> sign_in("github") |> complete("public@example.com")

      assert redirected_to(conn) == "/auth/verify-email"
      refute Repo.get_by(UserSchema, github_user_id: "5002")
    end
  end

  describe "a typed email" do
    test "is confirmed by email before any account exists, then signs the owner in" do
      stub_github(%{"id" => 6001, "email" => nil, "name" => "Squatter?"}, [])

      conn = sign_in(build_conn(), "github")
      assert redirected_to(conn) == "/auth/complete-registration"

      conn = complete(conn, "typed@example.com")

      assert redirected_to(conn) == "/auth/verify-email"
      refute get_session(conn, :user_token)
      assert Flash.get(conn.assigns.flash, :info) =~ "Check your email"
      refute Repo.get_by(UserSchema, github_user_id: "6001")

      # Until the link is followed the identity is not linked to anything, so
      # signing in with it again simply asks for an email again.
      assert redirected_to(sign_in(build_conn(), "github")) == "/auth/complete-registration"

      # Opening the link creates nothing (a mail scanner may prefetch it)...
      token = confirmation_link("typed@example.com")
      assert build_conn() |> get(~p"/auth/oauth/confirm/#{token}") |> html_response(200)
      refute Repo.get_by(UserSchema, github_user_id: "6001")

      # ...pressing its button creates the account, verified, and signs in.
      finished = post(build_conn(), ~p"/auth/oauth/confirm/#{token}")

      assert redirected_to(finished) == "/dashboard"
      assert get_session(finished, :user_token)
      assert Flash.get(finished.assigns.flash, :info) =~ "successfully signed up with GitHub"

      user = Repo.get_by!(UserSchema, github_user_id: "6001")
      assert user.email == "typed@example.com"
      assert user.verified_at

      # From then on, signing in with GitHub opens a session.
      login = sign_in(build_conn(), "github")
      assert redirected_to(login) == "/dashboard"
    end

    test "a taken address is indistinguishable from a free one, now and at the next sign-in" do
      insert(:user, email: "taken@example.com")

      outcomes =
        for {id, email} <- [{6003, "free@example.com"}, {6004, "taken@example.com"}] do
          stub_github(%{"id" => id, "email" => nil}, [])
          conn = build_conn() |> sign_in("github") |> complete(email)

          session =
            conn
            |> get_session()
            |> Map.take([
              "user_token",
              "unverified_user_id",
              "unverified_user_email",
              "pending_oauth_registration"
            ])

          next_sign_in = build_conn() |> sign_in("github") |> redirected_to()

          {redirected_to(conn), conn.assigns.flash, session, next_sign_in}
        end

      assert [same, same] = outcomes
      assert {"/auth/verify-email", _flash, %{}, "/auth/complete-registration"} = same
      refute Repo.get_by(UserSchema, github_user_id: "6003")
      refute Repo.get_by(UserSchema, github_user_id: "6004")

      # Only the mailboxes differ: a link for the free address, a notice for
      # the taken one's owner.
      assert confirmation_link("free@example.com")
      refute confirmation_link("taken@example.com")

      assert [_notice] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{"action" => "send_signup_attempt_notice"}
               )
    end

    test "a tampered or expired link creates nothing" do
      stub_github(%{"id" => 6005, "email" => nil}, [])
      build_conn() |> sign_in("github") |> complete("expiring@example.com")
      token = confirmation_link("expiring@example.com")

      tampered = post(build_conn(), ~p"/auth/oauth/confirm/#{token <> "x"}")
      assert redirected_to(tampered) == "/auth/login"
      assert Flash.get(tampered.assigns.flash, :error) =~ "no longer valid"

      # The same claims, signed a day and an hour ago.
      {:ok, claims} =
        Token.verify(Endpoint, @confirmation_salt, token, max_age: 60)

      stale =
        Token.sign(Endpoint, @confirmation_salt, claims,
          signed_at: System.system_time(:second) - 25 * 60 * 60
        )

      expired = post(build_conn(), ~p"/auth/oauth/confirm/#{stale}")
      assert redirected_to(expired) == "/auth/login"
      assert Flash.get(expired.assigns.flash, :error) =~ "no longer valid"
      refute Repo.get_by(UserSchema, github_user_id: "6005")

      # The genuine link still works, which shows the two above failed for
      # their own reasons.
      assert redirected_to(post(build_conn(), ~p"/auth/oauth/confirm/#{token}")) == "/dashboard"
    end

    test "reusing the link once the account exists only points to sign-in" do
      stub_github(%{"id" => 6006, "email" => nil}, [])
      build_conn() |> sign_in("github") |> complete("twice-clicked@example.com")
      token = confirmation_link("twice-clicked@example.com")

      assert redirected_to(post(build_conn(), ~p"/auth/oauth/confirm/#{token}")) == "/dashboard"

      again = post(build_conn(), ~p"/auth/oauth/confirm/#{token}")

      assert redirected_to(again) == "/auth/login"
      assert Flash.get(again.assigns.flash, :error) =~ "no longer valid"
      refute get_session(again, :user_token)
      assert Repo.aggregate(UserSchema, :count) == 1
    end

    test "an unverified account from before confirmation links gets the verify screen" do
      user =
        insert(:user,
          email: "legacy@example.com",
          provider: "github",
          github_user_id: "6002",
          password_hash: nil,
          verified_at: nil
        )

      stub_github(%{"id" => 6002, "email" => nil}, [])

      login = sign_in(build_conn(), "github")

      assert redirected_to(login) == "/auth/verify-email"
      refute get_session(login, :user_token)

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

    test "submitted twice with a typed email answers the same both times and creates nothing" do
      stub_github(%{"id" => 8004, "email" => nil}, [])

      form = sign_in(build_conn(), "github")

      first = complete(form, "twice-typed@example.com")
      second = complete(form, "twice-typed@example.com")

      assert redirected_to(first) == "/auth/verify-email"
      assert redirected_to(second) == "/auth/verify-email"
      refute get_session(second, :user_token)
      assert Flash.get(first.assigns.flash, :info) == Flash.get(second.assigns.flash, :info)
      assert Repo.aggregate(UserSchema, :count) == 0
    end
  end

  # Posts the complete-registration form from the conn the callback left.
  defp complete(conn, email \\ nil) do
    auth = if email, do: %{"email" => email}, else: %{}

    conn
    |> recycle()
    |> post(~p"/auth/complete", %{"auth" => auth, "profile" => %{"full_name" => "Test User"}})
  end

  # The token in the newest sign-up confirmation link sent to `email`, or nil.
  defp confirmation_link(email) do
    jobs =
      all_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_social_signup_confirmation", "email" => email}
      )

    case jobs do
      [] ->
        nil

      [job | _older] ->
        {:ok, url} = LinkArg.fetch(job.args, "confirm_url")
        url |> URI.parse() |> Map.fetch!(:path) |> Path.basename()
    end
  end
end
