defmodule TymeslotWeb.Plugs.ForgeryProtectionTest do
  # Exercised through the password login form, a real `:browser` form post:
  # a stale token must change nothing and send the visitor back to retry.
  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :security

  alias Phoenix.Flash
  alias Tymeslot.Factory
  alias Tymeslot.Security.Password

  @password "Password1234!"
  @retry_flash "Your session has changed since this page was opened. Please try again."

  setup %{conn: conn} do
    user =
      Factory.insert(:user,
        password: @password,
        password_hash: Password.hash_password(@password),
        verified_at: DateTime.utc_now()
      )

    %{conn: put_private(conn, :plug_skip_csrf_protection, false), user: user}
  end

  defp log_in(conn, user, params \\ %{}) do
    post(
      conn,
      ~p"/auth/session",
      Map.merge(%{"email" => user.email, "password" => @password}, params)
    )
  end

  test "a stale token signs nobody in and returns to the form it came from", %{
    conn: conn,
    user: user
  } do
    conn =
      conn
      |> put_req_header("referer", "http://www.example.com/auth/login?redirect_to=%2Fdashboard")
      |> log_in(user, %{"_csrf_token" => "stale-token"})

    assert redirected_to(conn) == "/auth/login?redirect_to=%2Fdashboard"
    assert Flash.get(conn.assigns.flash, :error) == @retry_flash
    refute get_session(conn, :user_token)
  end

  test "the retry message is in the visitor's language", %{conn: conn, user: user} do
    conn =
      conn
      |> put_req_header("accept-language", "de")
      |> log_in(user, %{"_csrf_token" => "stale-token"})

    assert Flash.get(conn.assigns.flash, :error) ==
             "Ihre Sitzung hat sich geändert, seit diese Seite geöffnet wurde. " <>
               "Bitte versuchen Sie es erneut."
  end

  test "a request from another site is sent to the home page", %{conn: conn, user: user} do
    conn =
      conn
      |> put_req_header("referer", "https://evil.example.org/auth/login")
      |> log_in(user)

    assert redirected_to(conn) == "/"
    refute get_session(conn, :user_token)
  end

  test "a referer path a browser would read as another host is not followed", %{
    conn: conn,
    user: user
  } do
    for path <- ["//evil.example.org/x", "/\\evil.example.org/x"] do
      conn =
        conn
        |> put_req_header("referer", "http://www.example.com" <> path)
        |> log_in(user)

      assert redirected_to(conn) == "/"
    end
  end

  test "without a referer the visitor is sent to the home page", %{conn: conn, user: user} do
    assert conn |> log_in(user) |> redirected_to() == "/"
  end

  test "a valid token is still accepted", %{conn: conn, user: user} do
    page = get(conn, ~p"/auth/login")

    [_match, csrf_token] =
      Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(page, 200))

    conn =
      page
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> log_in(user, %{"_csrf_token" => csrf_token})

    assert get_session(conn, :user_token)
  end
end
