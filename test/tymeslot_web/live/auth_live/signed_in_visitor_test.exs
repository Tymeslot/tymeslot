defmodule TymeslotWeb.AuthLive.SignedInVisitorTest do
  @moduledoc """
  What the authentication screens do for someone who is already signed in:
  the login and sign-up screens and the password login endpoint send them
  on, the emailed-link screens stay usable, and a second sign-in on the same
  browser replaces the first session rather than adding to it.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :auth
  @moduletag :live

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Tymeslot.Auth.{Session, UserSessionQueries, UserSessionSchema, UserTokenQueries}
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Password, Token}

  @password "Password1234!"

  setup %{conn: conn} do
    user =
      insert(:user,
        password_hash: Password.hash_password(@password),
        verified_at: DateTime.utc_now()
      )

    {:ok, conn, token} =
      conn
      |> init_test_session(%{})
      |> Session.create_session(user)

    %{conn: conn, user: user, token: token}
  end

  describe "screens a signed-in user is sent on from" do
    test "the login screen redirects to the dashboard", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/auth/login")
    end

    test "the sign-up screen redirects to the dashboard", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/auth/signup")
    end

    test "posting the login form does not mint a second session", %{
      conn: conn,
      user: user,
      token: token
    } do
      conn = post(conn, ~p"/auth/session", %{"email" => user.email, "password" => @password})

      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :info) =~ "already logged in"
      assert get_session(conn, :user_token) == token
      assert session_count(user) == 1
    end
  end

  describe "screens that stay reachable while signed in" do
    test "a password-reset link still shows the new-password form", %{conn: conn, user: user} do
      {reset_token, _expiry} = Token.generate_password_reset_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, reset_token)

      {:ok, _view, html} = live(conn, ~p"/auth/reset-password/#{reset_token}")

      assert html =~ "new-password-form"
    end

    test "the reset-request screen still renders", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/auth/reset-password")
    end
  end

  describe "signing in again on the same browser" do
    test "an email-verification sign-in revokes the session the browser already held", %{
      conn: conn,
      token: old_token
    } do
      verification_token = "verify-#{System.unique_integer([:positive])}"
      newcomer = insert(:user, verified_at: nil, signup_ip: "127.0.0.1")

      {:ok, _newcomer} =
        UserTokenQueries.set_verification_token(newcomer, verification_token, "127.0.0.1")

      conn = post(conn, ~p"/auth/verify-complete/#{verification_token}")

      assert redirected_to(conn) == "/dashboard"
      new_token = get_session(conn, :user_token)
      assert %{id: newcomer_id} = UserSessionQueries.get_user_by_session_token(new_token)
      assert newcomer_id == newcomer.id
      assert UserSessionQueries.get_user_by_session_token(old_token) == nil
    end
  end

  defp session_count(user) do
    Repo.aggregate(from(s in UserSessionSchema, where: s.user_id == ^user.id), :count)
  end
end
