defmodule TymeslotWeb.OAuthCallbackHandlerTest do
  use TymeslotWeb.ConnCase, async: false

  alias Phoenix.Flash
  alias Plug.Session
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.OAuthCallbackHandler

  setup %{conn: conn} do
    try do
      :meck.unload(RateLimiter)
    rescue
      _other -> :ok
    end

    :meck.new(RateLimiter, [:passthrough])

    conn =
      conn
      |> Map.put(:secret_key_base, String.duplicate("a", 64))
      |> Session.call(Session.init(store: :cookie, key: "_test", signing_salt: "salt"))
      |> fetch_session()
      |> fetch_flash()

    on_exit(fn ->
      try do
        :meck.unload(RateLimiter)
      rescue
        _other -> :ok
      end
    end)

    {:ok, conn: conn}
  end

  describe "handle_callback/3" do
    test "handles success", %{conn: conn} do
      opts = [
        service_name: "TestService",
        exchange_fun: fn _params -> {:ok, %{access_token: "abc", user_id: 123}} end,
        create_fun: fn _tokens -> {:ok, %{id: 1, user_id: 123}} end,
        redirect_path: "/success"
      ]

      conn = OAuthCallbackHandler.handle_callback(conn, %{"code" => "123"}, opts)

      assert redirected_to(conn) == "/success"
      assert Flash.get(conn.assigns.flash, :info) =~ "TestService connected successfully"
    end

    test "handles exchange failure", %{conn: conn} do
      opts = [
        service_name: "TestService",
        exchange_fun: fn _params -> {:error, :invalid_code} end,
        create_fun: fn _tokens -> {:ok, %{}} end,
        redirect_path: "/fail"
      ]

      conn = OAuthCallbackHandler.handle_callback(conn, %{"code" => "123"}, opts)

      assert redirected_to(conn) == "/fail"
      assert Flash.get(conn.assigns.flash, :error) =~ "Failed to connect TestService"
    end

    test "handles rate limiting", %{conn: conn} do
      :meck.expect(RateLimiter, :check_oauth_callback_rate_limit, fn _ip ->
        {:error, :rate_limited, "Too many requests"}
      end)

      opts = [
        service_name: "TestService",
        exchange_fun: fn _params -> {:ok, %{}} end,
        create_fun: fn _tokens -> {:ok, %{}} end,
        redirect_path: "/any"
      ]

      conn = OAuthCallbackHandler.handle_callback(conn, %{"code" => "123"}, opts)

      assert redirected_to(conn) == "/any"
      assert Flash.get(conn.assigns.flash, :error) =~ "Too many authentication attempts"
    end
  end

  describe "initiate_oauth/2" do
    test "redirects to external authorize URL", %{conn: conn} do
      opts = [
        service_name: "TestService",
        authorize_url_fun: fn conn -> {:ok, conn, "https://example.com/auth"} end
      ]

      conn = OAuthCallbackHandler.initiate_oauth(conn, opts)

      assert redirected_to(conn) == "https://example.com/auth"
    end

    test "handles generation failure", %{conn: conn} do
      opts = [
        service_name: "TestService",
        authorize_url_fun: fn _conn -> {:error, :config_missing} end,
        error_redirect: "/error-page"
      ]

      conn = OAuthCallbackHandler.initiate_oauth(conn, opts)

      assert redirected_to(conn) == "/error-page"

      assert Flash.get(conn.assigns.flash, :error) =~
               "Failed to initiate TestService authentication"
    end
  end
end
