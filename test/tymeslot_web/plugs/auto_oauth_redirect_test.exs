defmodule TymeslotWeb.AutoOAuthRedirectTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :auth
  @moduletag :plugs

  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.Factory, only: [insert: 1, insert: 2]
  import Tymeslot.Test.OAuthProviderStub

  alias Tymeslot.AuthTestHelpers

  setup :setup_providers

  setup do
    original_password = Application.get_env(:tymeslot, :password_auth_enabled)
    social_auth = Application.get_env(:tymeslot, :social_auth, [])

    Application.put_env(:tymeslot, :password_auth_enabled, false)

    Application.put_env(
      :tymeslot,
      :social_auth,
      Keyword.merge(social_auth,
        github_enabled: false,
        google_enabled: false,
        oauth_enabled: true
      )
    )

    on_exit(fn ->
      Application.put_env(:tymeslot, :password_auth_enabled, original_password)
      Application.put_env(:tymeslot, :social_auth, social_auth)
    end)
  end

  test "starts generic OAuth from the login page in SSO-only mode", %{conn: conn} do
    assert conn |> get(~p"/auth/login") |> redirected_to() == ~p"/auth/oauth"
  end

  test "starts generic OAuth from the root in SSO-only mode", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/auth/login"

    assert conn |> recycle() |> get(~p"/auth/login") |> redirected_to() == ~p"/auth/oauth"
  end

  test "keeps the existing dashboard redirect for an authenticated user", %{conn: conn} do
    user = insert(:user)

    assert conn
           |> AuthTestHelpers.log_in_user(user)
           |> get(~p"/auth/login")
           |> redirected_to() == ~p"/dashboard"
  end

  test "keeps the login page when password authentication is enabled", %{conn: conn} do
    Application.put_env(:tymeslot, :password_auth_enabled, true)

    assert conn |> get(~p"/auth/login") |> html_response(200)
  end

  test "keeps the provider choices when another social provider is enabled", %{conn: conn} do
    social_auth = Application.get_env(:tymeslot, :social_auth, [])

    for provider <- [:github_enabled, :google_enabled] do
      Application.put_env(
        :tymeslot,
        :social_auth,
        Keyword.put(social_auth, provider, true)
      )

      assert conn |> recycle() |> get(~p"/auth/login") |> html_response(200)
    end
  end

  test "returns to a protected deep link after the OAuth round trip", %{conn: conn} do
    user =
      insert(:user,
        email: "sso-host@example.com",
        provider: "oauth",
        provider_uid: "sso-auto-login",
        verified_at: ~U[2026-01-01 00:00:00Z]
      )

    stub_sso(%{
      "sub" => user.provider_uid,
      "email" => user.email,
      "email_verified" => true,
      "name" => "SSO Host"
    })

    link = "/dashboard/calendar?view=week"
    conn = get(conn, link)

    login = redirected_to(conn)
    assert login == "/auth/login?" <> URI.encode_query(%{"redirect_to" => link})

    conn = conn |> recycle() |> get(login)
    assert redirected_to(conn) == ~p"/auth/oauth"

    conn = conn |> recycle() |> get(~p"/auth/oauth")
    %{"state" => state} = conn |> redirected_to(302) |> authorise_params()

    conn =
      conn
      |> recycle()
      |> get(~p"/auth/oauth/callback", %{"code" => "provider-code", "state" => state})

    assert redirected_to(conn) == link
  end

  test "uses a fixed local OAuth start for unsafe return addresses" do
    for target <- ["https://evil.example/phish", "//evil.example/phish"] do
      conn = get(build_conn(), "/auth/login?" <> URI.encode_query(%{"redirect_to" => target}))

      assert redirected_to(conn) == ~p"/auth/oauth"
      assert get_session(conn, "return_to") == nil
    end
  end

  test "renders explicit signed-out and OAuth error landings" do
    for path <- ["/auth/login?signed_out=1", "/auth/login?error=oauth"] do
      assert build_conn() |> get(path) |> html_response(200)
    end
  end

  test "sign-out lands on a stable signed-out page", %{conn: conn} do
    user = insert(:user)

    conn =
      conn
      |> AuthTestHelpers.log_in_user(user)
      |> delete(~p"/auth/logout")

    landing = redirected_to(conn)
    assert landing == "/auth/login?signed_out=1"
    assert conn |> recycle() |> get(landing) |> html_response(200)
  end

  test "an OAuth callback failure lands on a stable error page", %{conn: conn} do
    conn =
      get(conn, ~p"/auth/oauth/callback", %{"code" => "code", "state" => "invalid"})

    landing = redirected_to(conn)
    assert landing == "/auth/login?error=oauth"
    assert conn |> recycle() |> get(landing) |> html_response(200)
  end

  test "a flash-bearing provider error does not restart OAuth", %{conn: conn} do
    conn = get(conn, "/auth/not-a-provider")
    assert redirected_to(conn) == ~p"/auth/login"

    assert conn |> recycle() |> get(~p"/auth/login") |> html_response(200)
  end

  test "registration and emailed-link routes keep their flash-bearing landings" do
    for path <- [~p"/auth/signup", ~p"/auth/reset-password"] do
      conn = get(build_conn(), path)
      assert redirected_to(conn) == ~p"/auth/login"

      assert conn |> recycle() |> get(~p"/auth/login") |> html_response(200)
    end
  end

  test "a public booking page does not start OAuth", %{conn: conn} do
    %{profile: profile} = seed_booking_account("1", "sso-public-host", "Etc/UTC")

    assert conn |> get("/#{profile.username}") |> html_response(200)
  end
end
