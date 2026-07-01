defmodule TymeslotWeb.AuthAliasControllerTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils

  describe "auth slug redirects" do
    test "GET /login redirects to /auth/login", %{conn: conn} do
      assert conn |> get(~p"/login") |> redirected_to() == "/auth/login"
    end

    test "GET /signin redirects to /auth/login", %{conn: conn} do
      assert conn |> get(~p"/signin") |> redirected_to() == "/auth/login"
    end

    test "GET /sign-in redirects to /auth/login", %{conn: conn} do
      assert conn |> get(~p"/sign-in") |> redirected_to() == "/auth/login"
    end

    test "GET /signup redirects to /auth/signup", %{conn: conn} do
      assert conn |> get(~p"/signup") |> redirected_to() == "/auth/signup"
    end

    test "GET /sign-up redirects to /auth/signup", %{conn: conn} do
      assert conn |> get(~p"/sign-up") |> redirected_to() == "/auth/signup"
    end

    test "GET /register redirects to /auth/signup", %{conn: conn} do
      assert conn |> get(~p"/register") |> redirected_to() == "/auth/signup"
    end
  end
end
