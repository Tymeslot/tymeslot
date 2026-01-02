defmodule TymeslotWeb.Auth.OAuthControllerTest do
  use TymeslotWeb.ConnCase, async: true

  alias Phoenix.Flash

  @moduletag :auth

  describe "OAuth security" do
    test "rejects OAuth callback without authorization code", %{conn: conn} do
      conn = get(conn, "/auth/google/callback", %{"state" => "some_state"})

      assert redirected_to(conn) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) =~
               "Google authentication failed - missing authorization code"
    end

    test "rejects OAuth callback with tampered state parameter", %{conn: conn} do
      conn =
        conn
        |> put_session(:oauth_state, "expected_state")
        |> get("/auth/google/callback", %{
          "code" => "auth_code",
          "state" => "tampered_state"
        })

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Security validation failed"
    end

    test "handles user cancellation gracefully", %{conn: conn} do
      conn =
        get(conn, "/auth/google/callback", %{
          "error" => "access_denied",
          "error_description" => "User denied access"
        })

      assert redirected_to(conn) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) =~
               "Google authentication failed - missing authorization code"
    end
  end
end
