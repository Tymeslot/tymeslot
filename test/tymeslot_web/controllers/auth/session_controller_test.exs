defmodule TymeslotWeb.SessionControllerTest do
  use TymeslotWeb.ConnCase, async: true

  alias Phoenix.Flash
  alias Tymeslot.AuthTestHelpers
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.Factory
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.Password

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

    test "handles unverified email", %{conn: conn, password: password} do
      user =
        Factory.insert(:user,
          password: password,
          password_hash: Password.hash_password(password),
          verified_at: nil
        )

      conn =
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => password
        })

      assert redirected_to(conn) == "/auth/verify-email"
      assert Flash.get(conn.assigns.flash, :error) =~ "Please verify your email"
      assert get_session(conn, :unverified_user_id) == user.id
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
    setup do
      %{token: "valid_token"}
    end

    defp insert_unverified_user(token, signup_ip) do
      Factory.insert(:user,
        verified_at: nil,
        verification_token: token,
        verification_sent_at: DateTime.utc_now(),
        signup_ip: signup_ip
      )
    end

    test "verifies and logs in user when IP matches", %{conn: conn, token: token} do
      user = insert_unverified_user(token, "127.0.0.1")

      conn = get(conn, ~p"/auth/verify-complete/#{token}")

      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :success) =~ "successfully verified"
      assert get_session(conn, :user_token)

      updated_user = UserQueries.get_user!(user.id)
      assert updated_user.verified_at
    end

    test "verifies but does NOT log in user when IP mismatch", %{conn: conn, token: token} do
      user = insert_unverified_user(token, "1.1.1.1")

      conn = get(conn, ~p"/auth/verify-complete/#{token}")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Please log in to continue"
      refute get_session(conn, :user_token)

      updated_user = UserQueries.get_user!(user.id)
      assert updated_user.verified_at
    end

    test "handles invalid token", %{conn: conn} do
      conn = get(conn, ~p"/auth/verify-complete/invalid_token")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
    end

    test "handles verification failure for existing user", %{conn: conn, token: token} do
      # Mock Verification.verify_user_token to fail
      # This requires meck or similar, but Verification is not mocked in this file yet.
      # Wait, I can just use a token that is valid for get_user_by_verification_token but fails verify_user_token.
      # But verify_user_token usually fails if the token is not in DB or expired.

      # Let's mock Verification
      try do
        :meck.unload(Tymeslot.Auth.Verification)
      rescue
        _other -> :ok
      end

      :meck.new(Tymeslot.Auth.Verification, [:passthrough])
      _unverified_user = insert_unverified_user(token, "127.0.0.1")

      :meck.expect(Tymeslot.Auth.Verification, :verify_user_token, fn ^token ->
        {:error, :expired}
      end)

      conn = get(conn, ~p"/auth/verify-complete/#{token}")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"

      :meck.unload(Tymeslot.Auth.Verification)
    end
  end
end
