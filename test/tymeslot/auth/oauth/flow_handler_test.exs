defmodule Tymeslot.Auth.OAuth.FlowHandlerTest do
  use Tymeslot.DataCase, async: false

  alias Phoenix.Controller
  alias Phoenix.Flash
  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.OAuth.{Client, FlowHandler, State, URLs, UserProcessor, UserRegistration}
  alias Tymeslot.Auth.Session
  import Phoenix.ConnTest, only: [redirected_to: 1]

  setup do
    modules = [Client, State, URLs, UserProcessor, UserRegistration, Session]

    Enum.each(modules, &unload_if_loaded/1)
    Enum.each(modules, &:meck.new(&1, [:passthrough]))

    on_exit(fn ->
      Enum.each(modules, &unload_if_loaded/1)
    end)

    :ok
  end

  test "redirects to login when state is invalid" do
    conn =
      PlugTest.conn(:get, "/")
      |> PlugTest.init_test_session(%{})
      |> Controller.fetch_flash([])

    :meck.expect(State, :validate_state, fn _conn, "bad-state" ->
      {:error, :invalid_state}
    end)

    conn =
      FlowHandler.handle_oauth_callback(conn, %{
        code: "code",
        state: "bad-state",
        provider: :github
      })

    assert redirected_to(conn) == "/auth/login"

    assert Flash.get(conn.assigns.flash, :error) ==
             "Security validation failed. Please try again."
  end

  test "creates a session and redirects on successful existing user login" do
    conn =
      PlugTest.conn(:get, "/")
      |> PlugTest.init_test_session(%{})
      |> Controller.fetch_flash([])

    user_info = %{"id" => 123}

    processed_user = %{
      email: "user@example.com",
      github_user_id: 123,
      name: "Test",
      is_verified: true
    }

    enhanced_user = Map.put(processed_user, :email_from_provider, true)
    existing_user = %{id: 987}

    :meck.expect(State, :validate_state, fn _conn, "state" -> :ok end)
    :meck.expect(State, :clear_oauth_state, fn conn -> conn end)

    :meck.expect(URLs, :callback_path, fn :github -> "/auth/github/callback" end)

    :meck.expect(URLs, :callback_url, fn _conn, "/auth/github/callback" ->
      "https://example.com/auth/github/callback"
    end)

    :meck.expect(Client, :build, fn :github, "https://example.com/auth/github/callback", "" ->
      :oauth_client
    end)

    :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
      {:ok, :authed_client}
    end)

    :meck.expect(Client, :get_user_info, fn :authed_client, :github ->
      {:ok, user_info}
    end)

    :meck.expect(UserProcessor, :process_user, fn :github, ^user_info ->
      {:ok, processed_user}
    end)

    :meck.expect(UserProcessor, :enhance_user_data, fn :github, ^processed_user, :authed_client ->
      enhanced_user
    end)

    :meck.expect(UserRegistration, :find_existing_user, fn :github, ^enhanced_user ->
      {:ok, existing_user}
    end)

    :meck.expect(Session, :create_session, fn conn, %{id: 987} ->
      {:ok, conn, "token"}
    end)

    conn =
      FlowHandler.handle_oauth_callback(conn, %{
        code: "code",
        state: "state",
        provider: :github,
        opts: [success_path: "/dashboard"]
      })

    assert redirected_to(conn) == "/dashboard"
    assert Flash.get(conn.assigns.flash, :info) == "Successfully signed in with GitHub."
  end

  test "redirects to registration flow with missing fields" do
    conn =
      PlugTest.conn(:get, "/")
      |> PlugTest.init_test_session(%{})
      |> Controller.fetch_flash([])

    user_info = %{"id" => 123}
    processed_user = %{email: nil, github_user_id: 123, name: "New User", is_verified: false}
    enhanced_user = Map.put(processed_user, :email_from_provider, false)

    :meck.expect(State, :validate_state, fn _conn, "state" -> :ok end)
    :meck.expect(State, :clear_oauth_state, fn conn -> conn end)

    :meck.expect(URLs, :callback_path, fn :github -> "/auth/github/callback" end)

    :meck.expect(URLs, :callback_url, fn _conn, "/auth/github/callback" ->
      "https://example.com/auth/github/callback"
    end)

    :meck.expect(Client, :build, fn :github, "https://example.com/auth/github/callback", "" ->
      :oauth_client
    end)

    :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
      {:ok, :authed_client}
    end)

    :meck.expect(Client, :get_user_info, fn :authed_client, :github ->
      {:ok, user_info}
    end)

    :meck.expect(UserProcessor, :process_user, fn :github, ^user_info ->
      {:ok, processed_user}
    end)

    :meck.expect(UserProcessor, :enhance_user_data, fn :github, ^processed_user, :authed_client ->
      enhanced_user
    end)

    :meck.expect(UserRegistration, :find_existing_user, fn :github, ^enhanced_user ->
      {:error, :not_found}
    end)

    :meck.expect(UserRegistration, :check_oauth_requirements, fn :github, ^enhanced_user ->
      {:missing, [:email]}
    end)

    conn =
      FlowHandler.handle_oauth_callback(conn, %{
        code: "code",
        state: "state",
        provider: :github,
        opts: [registration_path: "/auth/complete-registration"]
      })

    assert redirected_to(conn) =~ "/auth/complete-registration?"

    query_params =
      conn
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert query_params["auth"] == "oauth_complete"
    assert query_params["oauth_provider"] == "github"
    assert query_params["oauth_missing"] == "email"
    assert query_params["oauth_email"] == ""
    assert query_params["oauth_verified"] == "false"
    assert query_params["oauth_email_from_provider"] == "false"
    assert query_params["oauth_github_id"] == "123"
    assert query_params["oauth_name"] == "New User"
  end

  test "redirects to login when provider returns oauth error" do
    conn =
      PlugTest.conn(:get, "/")
      |> PlugTest.init_test_session(%{})
      |> Controller.fetch_flash([])

    :meck.expect(State, :validate_state, fn _conn, "state" -> :ok end)
    :meck.expect(State, :clear_oauth_state, fn conn -> conn end)

    :meck.expect(URLs, :callback_path, fn :github -> "/auth/github/callback" end)

    :meck.expect(URLs, :callback_url, fn _conn, "/auth/github/callback" ->
      "https://example.com/auth/github/callback"
    end)

    :meck.expect(Client, :build, fn :github, "https://example.com/auth/github/callback", "" ->
      :oauth_client
    end)

    :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
      {:error, %OAuth2.Error{reason: "access_denied"}}
    end)

    conn =
      FlowHandler.handle_oauth_callback(conn, %{
        code: "code",
        state: "state",
        provider: :github,
        opts: [login_path: "/auth/login"]
      })

    assert redirected_to(conn) == "/auth/login"
    assert Flash.get(conn.assigns.flash, :error) == "Failed to authenticate with GitHub."
  end

  defp unload_if_loaded(module) do
    :meck.unload(module)
  rescue
    _error -> :ok
  end
end
