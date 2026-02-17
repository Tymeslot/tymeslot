defmodule TymeslotWeb.EmailChangeControllerTest do
  # Uses global ETS rate limiter state; must not run concurrently.
  use TymeslotWeb.ConnCase, async: false

  alias Ecto.Changeset
  alias Phoenix.Flash
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.Factory
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.Token

  setup do
    RateLimiter.clear_all()
    :ok
  end

  describe "GET /email-change/:token" do
    test "verifies email change with valid token", %{conn: conn} do
      user = Factory.insert(:user, email: "old@example.com")
      new_email = "new@example.com"
      token = Token.generate_token()

      {:ok, _user} = UserQueries.request_email_change(user, new_email, token)

      conn = get(conn, ~p"/email-change/#{token}")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Email changed successfully"

      # Verify email actually changed in DB
      updated_user = UserQueries.get_user!(user.id)
      assert updated_user.email == new_email
    end

    test "fails with invalid token", %{conn: conn} do
      conn = get(conn, ~p"/email-change/invalid-token")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Invalid or expired"
    end

    test "fails with expired token", %{conn: conn} do
      user = Factory.insert(:user, email: "old@example.com")
      new_email = "new@example.com"
      token = Token.generate_token()

      {:ok, _user} = UserQueries.request_email_change(user, new_email, token)

      # Manually expire the token in DB
      user_in_db = UserQueries.get_user!(user.id)
      expired_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), -49, :hour), :second)

      user_in_db
      |> Changeset.change(email_change_sent_at: expired_at)
      |> Repo.update!()

      conn = get(conn, ~p"/email-change/#{token}")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "has expired"
    end

    test "is rate limited", %{conn: conn} do
      # 30 requests allowed per minute per IP
      conn =
        Enum.reduce(1..30, conn, fn _attempt, acc ->
          get(acc, ~p"/email-change/some-token")
        end)

      conn = get(conn, ~p"/email-change/some-token")
      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Too many attempts"
    end
  end
end
