defmodule Tymeslot.Auth.OAuth.FlowHandlerTest do
  use Tymeslot.DataCase, async: false
  @moduletag :auth

  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.OAuth.{Client, FlowHandler, State, URLs, UserProcessor, UserRegistration}
  alias Tymeslot.Auth.Session

  setup do
    modules = [Client, State, URLs, UserProcessor, UserRegistration, Session]

    Enum.each(modules, &unload_if_loaded/1)
    Enum.each(modules, &:meck.new(&1, [:passthrough]))

    on_exit(fn ->
      Enum.each(modules, &unload_if_loaded/1)
    end)

    :ok
  end

  defp base_conn do
    PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
  end

  # Sets up State validation, URL resolution, and Client build mocks — the
  # common prefix shared by every test that reaches the token-exchange step.
  defp setup_pre_exchange_mocks do
    :meck.expect(State, :validate_state, fn _conn, "state" -> :ok end)
    :meck.expect(State, :clear_oauth_state, fn conn -> conn end)
    :meck.expect(URLs, :callback_path, fn :github -> "/auth/github/callback" end)

    :meck.expect(URLs, :callback_url, fn _conn, "/auth/github/callback" ->
      "https://example.com/auth/github/callback"
    end)

    :meck.expect(Client, :build, fn :github, "https://example.com/auth/github/callback", "" ->
      :oauth_client
    end)
  end

  # Sets up the full chain through find_existing_user for an existing GitHub
  # user. Returns {processed_user, enhanced_user, existing_user} for tests that
  # need to reference or override individual steps.
  defp setup_existing_user_flow_mocks do
    user_info = %{"id" => 123}
    processed_user = %{email: "user@example.com", github_user_id: 123, name: "Test", is_verified: true}
    enhanced_user = Map.put(processed_user, :email_from_provider, true)
    existing_user = %{id: 987}

    setup_pre_exchange_mocks()

    :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
      {:ok, :authed_client}
    end)

    :meck.expect(Client, :get_user_info, fn :authed_client, :github -> {:ok, user_info} end)
    :meck.expect(UserProcessor, :process_user, fn :github, ^user_info -> {:ok, processed_user} end)

    :meck.expect(UserProcessor, :enhance_user_data, fn :github, ^processed_user, :authed_client ->
      enhanced_user
    end)

    :meck.expect(UserRegistration, :find_existing_user, fn :github, ^enhanced_user ->
      {:ok, existing_user}
    end)

    {processed_user, enhanced_user, existing_user}
  end

  defp invoke_github_callback(conn \\ nil) do
    FlowHandler.handle_oauth_callback(conn || base_conn(), %{
      code: "code",
      state: "state",
      provider: :github
    })
  end

  test "returns {:error, :invalid_state, conn} when state is invalid" do
    :meck.expect(State, :validate_state, fn _conn, "bad-state" -> {:error, :invalid_state} end)

    conn = base_conn()

    assert {:error, :invalid_state, ^conn} =
             FlowHandler.handle_oauth_callback(conn, %{
               code: "code",
               state: "bad-state",
               provider: :github
             })
  end

  test "returns {:ok, conn, provider} on successful login for existing user" do
    {_processed_user, _enhanced_user, _existing_user} = setup_existing_user_flow_mocks()
    :meck.expect(Session, :create_session, fn conn, %{id: 987} -> {:ok, conn, "token"} end)

    assert {:ok, _conn, :github} = invoke_github_callback()
  end

  test "returns {:error, :session_failed, provider, conn} when session creation fails" do
    {_processed_user, _enhanced_user, _existing_user} = setup_existing_user_flow_mocks()

    :meck.expect(Session, :create_session, fn _conn, %{id: 987} ->
      {:error, :db_error, "failed"}
    end)

    assert {:error, :session_failed, :github, _conn} = invoke_github_callback()
  end

  test "returns {:registration_required, conn, provider, params} with missing fields" do
    user_info = %{"id" => 123}
    processed_user = %{email: nil, github_user_id: 123, name: "New User", is_verified: false}
    enhanced_user = Map.put(processed_user, :email_from_provider, false)

    setup_pre_exchange_mocks()

    :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
      {:ok, :authed_client}
    end)

    :meck.expect(Client, :get_user_info, fn :authed_client, :github -> {:ok, user_info} end)
    :meck.expect(UserProcessor, :process_user, fn :github, ^user_info -> {:ok, processed_user} end)

    :meck.expect(UserProcessor, :enhance_user_data, fn :github, ^processed_user, :authed_client ->
      enhanced_user
    end)

    :meck.expect(UserRegistration, :find_existing_user, fn :github, ^enhanced_user ->
      {:error, :not_found}
    end)

    :meck.expect(UserRegistration, :check_oauth_requirements, fn :github, ^enhanced_user ->
      {:missing, [:email]}
    end)

    assert {:registration_required, _conn, :github, params} = invoke_github_callback()

    assert params["auth"] == "oauth_complete"
    assert params["oauth_provider"] == "github"
    assert params["oauth_missing"] == "email"
    assert params["oauth_email"] == ""
    assert params["oauth_verified"] == "false"
    assert params["oauth_email_from_provider"] == "false"
    assert params["oauth_github_id"] == "123"
    assert params["oauth_name"] == "New User"
  end

  test "returns {:registration_required, conn, provider, params} with empty missing_fields when data is complete" do
    user_info = %{"id" => 456}
    processed_user = %{email: "complete@example.com", github_user_id: 456, name: "Full User", is_verified: true}
    enhanced_user = Map.put(processed_user, :email_from_provider, true)

    setup_pre_exchange_mocks()

    :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
      {:ok, :authed_client}
    end)

    :meck.expect(Client, :get_user_info, fn :authed_client, :github -> {:ok, user_info} end)
    :meck.expect(UserProcessor, :process_user, fn :github, ^user_info -> {:ok, processed_user} end)

    :meck.expect(UserProcessor, :enhance_user_data, fn :github, ^processed_user, :authed_client ->
      enhanced_user
    end)

    :meck.expect(UserRegistration, :find_existing_user, fn :github, ^enhanced_user ->
      {:error, :not_found}
    end)

    :meck.expect(UserRegistration, :check_oauth_requirements, fn :github, ^enhanced_user ->
      :complete
    end)

    assert {:registration_required, _conn, :github, params} = invoke_github_callback()

    assert params["oauth_missing"] == ""
    assert params["oauth_email"] == "complete@example.com"
  end

  test "returns {:error, :oauth_error, provider, conn} when provider returns OAuth2 error" do
    setup_pre_exchange_mocks()

    :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
      {:error, %OAuth2.Error{reason: "access_denied"}}
    end)

    assert {:error, :oauth_error, :github, _conn} = invoke_github_callback()
  end

  test "returns {:error, :general_error, provider, conn} on unexpected token exchange failure" do
    setup_pre_exchange_mocks()

    :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
      {:error, :timeout}
    end)

    assert {:error, :general_error, :github, _conn} = invoke_github_callback()
  end

  describe "generic OAuth (:oauth) provider flow" do
    defp setup_oauth_pre_exchange_mocks do
      :meck.expect(State, :validate_state, fn _conn, "state" -> :ok end)
      :meck.expect(State, :clear_oauth_state, fn conn -> conn end)
      :meck.expect(URLs, :callback_path, fn :oauth -> "/auth/oauth/callback" end)

      :meck.expect(URLs, :callback_url, fn _conn, "/auth/oauth/callback" ->
        "https://example.com/auth/oauth/callback"
      end)

      :meck.expect(Client, :build, fn :oauth, "https://example.com/auth/oauth/callback", "" ->
        :oauth_client
      end)
    end

    test "returns {:ok, conn, :oauth} on successful login for existing generic OAuth user" do
      user_info = %{"sub" => "user-123", "email" => "sso@example.com"}
      processed_user = %{email: "sso@example.com", provider_uid: "user-123", name: "SSO User", is_verified: true}
      enhanced_user = Map.put(processed_user, :email_from_provider, true)
      existing_user = %{id: 456}

      setup_oauth_pre_exchange_mocks()

      :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
        {:ok, :authed_client}
      end)

      :meck.expect(Client, :get_user_info, fn :authed_client, :oauth -> {:ok, user_info} end)
      :meck.expect(UserProcessor, :process_user, fn :oauth, ^user_info -> {:ok, processed_user} end)

      :meck.expect(UserProcessor, :enhance_user_data, fn :oauth, ^processed_user, :authed_client ->
        enhanced_user
      end)

      :meck.expect(UserRegistration, :find_existing_user, fn :oauth, ^enhanced_user ->
        {:ok, existing_user}
      end)

      :meck.expect(Session, :create_session, fn conn, %{id: 456} -> {:ok, conn, "token"} end)

      assert {:ok, _conn, :oauth} =
               FlowHandler.handle_oauth_callback(base_conn(), %{
                 code: "code",
                 state: "state",
                 provider: :oauth
               })
    end

    test "returns {:registration_required, ...} with provider_uid param for new generic OAuth user" do
      user_info = %{"sub" => "new-user-789", "email" => "new-sso@example.com"}
      processed_user = %{email: "new-sso@example.com", provider_uid: "new-user-789", name: "New SSO", is_verified: true}
      enhanced_user = Map.put(processed_user, :email_from_provider, true)

      setup_oauth_pre_exchange_mocks()

      :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
        {:ok, :authed_client}
      end)

      :meck.expect(Client, :get_user_info, fn :authed_client, :oauth -> {:ok, user_info} end)
      :meck.expect(UserProcessor, :process_user, fn :oauth, ^user_info -> {:ok, processed_user} end)

      :meck.expect(UserProcessor, :enhance_user_data, fn :oauth, ^processed_user, :authed_client ->
        enhanced_user
      end)

      :meck.expect(UserRegistration, :find_existing_user, fn :oauth, ^enhanced_user ->
        {:error, :not_found}
      end)

      :meck.expect(UserRegistration, :check_oauth_requirements, fn :oauth, ^enhanced_user ->
        :complete
      end)

      assert {:registration_required, _conn, :oauth, params} =
               FlowHandler.handle_oauth_callback(base_conn(), %{
                 code: "code",
                 state: "state",
                 provider: :oauth
               })

      assert params["oauth_provider"] == "oauth"
      assert params["oauth_provider_uid"] == "new-user-789"
      assert params["oauth_email"] == "new-sso@example.com"
    end
  end

  defp unload_if_loaded(module) do
    :meck.unload(module)
  rescue
    _error -> :ok
  end
end
