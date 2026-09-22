defmodule TymeslotWeb.EmailChangeControllerTest do
  # Uses global ETS rate limiter state; must not run concurrently.
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils
  @moduletag :auth

  alias Ecto.Changeset
  alias Phoenix.Flash
  alias Tymeslot.Auth.UserTokenQueries
  alias Tymeslot.Factory
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.Token

  setup do
    RateLimiter.clear_all()
    :ok
  end

  describe "GET /email-change/:token" do
    test "renders a confirmation page without changing the email", %{conn: conn} do
      user = Factory.insert(:user, email: "old@example.com")
      token = Token.generate_token()
      {:ok, _user} = UserTokenQueries.request_email_change(user, "new@example.com", token)

      conn = get(conn, ~p"/email-change/#{token}")

      html = html_response(conn, 200)
      assert html =~ ~s(action="/email-change/#{token}")
      assert html =~ ~s(method="post")
      assert Repo.reload!(user).email == "old@example.com"
    end
  end

  describe "POST /email-change/:token" do
    test "verifies email change with valid token", %{conn: conn} do
      user = Factory.insert(:user, email: "old@example.com")
      new_email = "new@example.com"
      token = Token.generate_token()

      {:ok, _user} = UserTokenQueries.request_email_change(user, new_email, token)

      conn = post(conn, ~p"/email-change/#{token}")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Email changed successfully"

      # Verify email actually changed in DB
      updated_user = Repo.reload!(user)
      assert updated_user.email == new_email
    end

    test "fails with invalid token", %{conn: conn} do
      conn = post(conn, ~p"/email-change/invalid-token")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Invalid or expired"
    end

    test "fails with expired token", %{conn: conn} do
      user = Factory.insert(:user, email: "old@example.com")
      new_email = "new@example.com"
      token = Token.generate_token()

      {:ok, _user} = UserTokenQueries.request_email_change(user, new_email, token)

      # Manually expire the token in DB
      user_in_db = Repo.reload!(user)
      expired_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), -49, :hour), :second)

      user_in_db
      |> Changeset.change(email_change_sent_at: expired_at)
      |> Repo.update!()

      conn = post(conn, ~p"/email-change/#{token}")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "has expired"
    end

    test "is rate limited", %{conn: conn} do
      # 30 requests allowed per minute per IP
      conn =
        Enum.reduce(1..30, conn, fn _attempt, acc ->
          post(acc, ~p"/email-change/some-token")
        end)

      conn = post(conn, ~p"/email-change/some-token")
      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "reached the limit of 30"
    end
  end
end
