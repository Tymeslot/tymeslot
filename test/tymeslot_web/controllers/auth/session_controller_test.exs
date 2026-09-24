defmodule TymeslotWeb.SessionControllerTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :auth

  alias Phoenix.Flash
  alias Tymeslot.Auth.UserTokenQueries
  alias Tymeslot.AuthTestHelpers
  alias Tymeslot.Factory
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Password, RateLimiter}

  describe "POST /auth/session" do
    setup do
      password = "Password1234!"

      user =
        Factory.insert(:user,
          password: password,
          password_hash: Password.hash_password(password),
          verified_at: DateTime.utc_now()
        )

      %{user: user, password: password}
    end

    test "logs in user with valid credentials", %{conn: conn, user: user, password: password} do
      conn =
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => password
        })

      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :info) =~ "Login successful"
      assert get_session(conn, :user_token)
    end

    test "redirects to custom path after login", %{conn: conn, user: user, password: password} do
      conn =
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => password,
          "redirect_to" => "/onboarding"
        })

      assert redirected_to(conn) == "/onboarding"
    end

    test "rejects external redirect_to and falls back to default", %{
      conn: conn,
      user: user,
      password: password
    } do
      conn =
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => password,
          "redirect_to" => "https://evil.example.com/phish"
        })

      assert redirected_to(conn) == Config.success_redirect_path()
    end

    test "rejects protocol-relative redirect //evil.com", %{
      conn: conn,
      user: user,
      password: password
    } do
      conn =
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => password,
          "redirect_to" => "//evil.com"
        })

      assert redirected_to(conn) == Config.success_redirect_path()
    end

    test "rejects path with backslash host injection /\\@evil.com", %{
      conn: conn,
      user: user,
      password: password
    } do
      conn =
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => password,
          "redirect_to" => "/\\@evil.com"
        })

      assert redirected_to(conn) == Config.success_redirect_path()
    end

    test "fails with empty email and password", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/session", %{
          "email" => "",
          "password" => ""
        })

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) == "Please enter your email and password."
      refute get_session(conn, :user_token)
    end

    test "fails with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => "WrongPassword123!"
        })

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Invalid email or password"
      refute get_session(conn, :user_token)
    end

    test "an unverified account with its password looks like a failed login",
         %{conn: conn, password: password} do
      user =
        Factory.insert(:user,
          password: password,
          password_hash: Password.hash_password(password),
          verified_at: nil
        )

      conn = post(conn, ~p"/auth/session", %{"email" => user.email, "password" => password})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) == unknown_account_error()
      refute get_session(conn, :user_token)
      refute get_session(conn, :unverified_user_id)
      refute get_session(conn, :unverified_user_email)
    end

    test "a wrong password for an unverified account reveals nothing about it",
         %{conn: conn, password: password} do
      user =
        Factory.insert(:user,
          password_hash: Password.hash_password(password),
          verified_at: nil
        )

      conn = post(conn, ~p"/auth/session", %{"email" => user.email, "password" => "Wrong1234!"})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) == unknown_account_error()
      refute get_session(conn, :unverified_user_id)
      refute get_session(conn, :unverified_user_email)
    end

    test "an account without a password gets the generic error", %{conn: conn} do
      user = Factory.insert(:user, provider: "google", password_hash: nil)

      conn = post(conn, ~p"/auth/session", %{"email" => user.email, "password" => "Any1234!"})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) == unknown_account_error()
    end

    # The flash an address with no account gets; every failure before the
    # password is proved must read the same.
    defp unknown_account_error do
      conn =
        post(build_conn(), ~p"/auth/session", %{
          "email" => "nobody-#{System.unique_integer([:positive])}@example.com",
          "password" => "Any1234!"
        })

      Flash.get(conn.assigns.flash, :error)
    end
  end

  describe "POST /auth/session — password auth disabled" do
    setup do
      original = Application.get_env(:tymeslot, :password_auth_enabled)
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :password_auth_enabled, original) end)

      password = "Password1234!"

      user =
        Factory.insert(:user,
          password: password,
          password_hash: Password.hash_password(password),
          verified_at: DateTime.utc_now()
        )

      %{user: user, password: password}
    end

    test "rejects password login and redirects with error flash", %{
      conn: conn,
      user: user,
      password: password
    } do
      conn =
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => password
        })

      assert redirected_to(conn) == "/auth/login"

      assert Flash.get(conn.assigns.flash, :error) =~
               "Password authentication is currently disabled"

      refute get_session(conn, :user_token)
    end
  end

  describe "rate limiting — POST /auth/session" do
    setup do
      on_exit(fn -> RateLimiter.clear_all() end)

      password = "Password1234!"

      user =
        Factory.insert(:user,
          password: password,
          password_hash: Password.hash_password(password),
          verified_at: DateTime.utc_now()
        )

      %{user: user, password: password}
    end

    test "blocks login after 10 failed attempts for the same email", %{conn: conn, user: user} do
      for _i <- 1..10 do
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => "WrongPassword123!"
        })
      end

      conn =
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => "WrongPassword123!"
        })

      assert redirected_to(conn) == "/auth/login"
      # AccountLockout throttle kicks in at 10 attempts; message differs from normal auth failure
      assert Flash.get(conn.assigns.flash, :error) ==
               "Too many failed attempts. Please wait before trying again"
    end

    test "failed attempts from one address do not lock the owner out from another", %{
      conn: conn,
      user: user,
      password: password
    } do
      attacker_ip = {198, 51, 100, 23}
      owner_ip = {203, 0, 113, 45}

      for _i <- 1..10 do
        post(%{conn | remote_ip: attacker_ip}, ~p"/auth/session", %{
          "email" => user.email,
          "password" => "WrongPassword123!"
        })
      end

      # The attacker's own address is throttled for this account...
      blocked =
        post(%{conn | remote_ip: attacker_ip}, ~p"/auth/session", %{
          "email" => user.email,
          "password" => password
        })

      assert Flash.get(blocked.assigns.flash, :error) ==
               "Too many failed attempts. Please wait before trying again"

      # ...but the owner, from their own address, still signs in.
      conn =
        post(%{conn | remote_ip: owner_ip}, ~p"/auth/session", %{
          "email" => user.email,
          "password" => password
        })

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :user_token)
    end

    test "blocks login after 50 attempts from the same IP across different emails", %{conn: conn} do
      rate_limit_ip = {10, 88, 88, 1}

      for _i <- 1..50 do
        victim = Factory.insert(:user, verified_at: DateTime.utc_now())

        post(%{conn | remote_ip: rate_limit_ip}, ~p"/auth/session", %{
          "email" => victim.email,
          "password" => "WrongPassword123!"
        })
      end

      overflow_user = Factory.insert(:user, verified_at: DateTime.utc_now())

      conn =
        post(%{conn | remote_ip: rate_limit_ip}, ~p"/auth/session", %{
          "email" => overflow_user.email,
          "password" => "WrongPassword123!"
        })

      assert redirected_to(conn) == "/auth/login"
      # IP Hammer bucket triggers, naming the per-IP budget rather than the account.
      assert Flash.get(conn.assigns.flash, :error) ==
               "You've reached the limit of 50 authentication (ip) actions per 30 minutes. " <>
                 "Please try again in 30 minutes."
    end
  end

  describe "DELETE /auth/logout" do
    test "logs out user", %{conn: conn} do
      user = Factory.insert(:user)
      conn = conn |> AuthTestHelpers.log_in_user(user) |> delete(~p"/auth/logout")

      assert redirected_to(conn) == "/"
      assert Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
      refute get_session(conn, :user_token)
    end
  end

  describe "GET /auth/verify-complete/:token" do
    test "renders a confirmation page without verifying the address", %{conn: conn} do
      user = Factory.insert(:user, verified_at: nil, signup_ip: "127.0.0.1")

      {:ok, _user} =
        UserTokenQueries.set_verification_token(user, "prefetched_token", "127.0.0.1")

      conn = get(conn, ~p"/auth/verify-complete/prefetched_token")

      html = html_response(conn, 200)
      assert html =~ ~s(action="/auth/verify-complete/prefetched_token")
      assert html =~ ~s(method="post")
      refute get_session(conn, :user_token)
      refute Repo.reload!(user).verified_at
    end
  end

  describe "POST /auth/verify-complete/:token" do
    setup do
      %{token: "valid_token"}
    end

    defp insert_unverified_user(token, signup_ip) do
      user =
        Factory.insert(:user,
          verified_at: nil,
          signup_ip: signup_ip
        )

      {:ok, user} = UserTokenQueries.set_verification_token(user, token, signup_ip)
      user
    end

    test "verifies and logs in user when IP matches", %{conn: conn, token: token} do
      user = insert_unverified_user(token, "127.0.0.1")

      conn = post(conn, ~p"/auth/verify-complete/#{token}")

      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :success) =~ "successfully verified"
      assert get_session(conn, :user_token)

      updated_user = Repo.reload!(user)
      assert updated_user.verified_at
    end

    test "verifies but does NOT log in user when IP mismatch", %{conn: conn, token: token} do
      user = insert_unverified_user(token, "1.1.1.1")

      conn = post(conn, ~p"/auth/verify-complete/#{token}")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Please log in to continue"
      refute get_session(conn, :user_token)

      updated_user = Repo.reload!(user)
      assert updated_user.verified_at
    end

    test "handles invalid token", %{conn: conn} do
      conn = post(conn, ~p"/auth/verify-complete/invalid_token")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "no longer valid"
    end

    test "refuses a client past 30 links a minute, leaving the token unspent", %{
      conn: conn,
      token: token
    } do
      user = insert_unverified_user(token, "10.77.0.1")
      client = %{conn | remote_ip: {10, 77, 0, 1}}

      for _i <- 1..30 do
        refused = post(client, ~p"/auth/verify-complete/not-a-token")
        assert Flash.get(refused.assigns.flash, :error) =~ "no longer valid"
      end

      conn = post(client, ~p"/auth/verify-complete/#{token}")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "reached the limit"
      refute get_session(conn, :user_token)
      refute Repo.reload!(user).verified_at
    end

    test "handles expired verification token", %{conn: conn} do
      expired_time = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)

      user = Factory.insert(:user, verified_at: nil, signup_ip: "127.0.0.1")
      {:ok, _token} = UserTokenQueries.set_verification_token(user, "expired_verification_token")

      Repo.query!(
        "UPDATE users SET verification_sent_at = $1 WHERE id = $2",
        [expired_time, user.id]
      )

      conn = post(conn, ~p"/auth/verify-complete/expired_verification_token")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "has expired"
      refute Repo.reload!(user).verified_at
    end
  end
end
