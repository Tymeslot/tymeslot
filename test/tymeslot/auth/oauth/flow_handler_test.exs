# :meck migration scope (assessed 2026-03-29):
# - This file uses :meck to mock 6 modules:
#     Client, State, URLs, UserProcessor, UserRegistration, Session
# - 54 :meck.expect calls across 10 tests
# - Modules with existing @behaviour + Mox mock:
#     Client (ClientBehaviour / Tymeslot.Auth.OAuth.ClientMock)
#     Session (SessionBehaviour / Tymeslot.Auth.SessionMock)
# - Internal modules currently mocked:
#     State, URLs, UserProcessor, UserRegistration
#   Per project test philosophy ("mock at system boundaries only"),
#   these internal module mocks should be removed entirely — not
#   migrated to Mox. The correct fix is to test FlowHandler through
#   its real dependencies with a DB-backed test, mocking only the
#   external HTTP calls (Client) and session storage (Session).
# - Estimated effort: complex
# - See docs/superpowers/plans/2026-03-29-test-suite-improvements.md Task 18
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

    processed_user = %{
      email: "user@example.com",
      github_user_id: 123,
      name: "Test",
      is_verified: true
    }

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

  test "emits an anonymous login_completed telemetry event on existing-user OAuth login" do
    {_processed_user, _enhanced_user, _existing_user} = setup_existing_user_flow_mocks()
    :meck.expect(Session, :create_session, fn conn, %{id: 987} -> {:ok, conn, "token"} end)

    test_pid = self()
    handler_id = {__MODULE__, :login_completed, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:tymeslot, :auth, :login_completed],
      fn _event, measurements, meta, _config ->
        send(test_pid, {:login_completed, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _conn, :github} = invoke_github_callback()

    assert_receive {:login_completed, %{count: 1}, meta}
    assert meta.method == "oauth"
    assert meta.provider == "github"
    # No user identifier may ride along in the telemetry metadata.
    refute Map.has_key?(meta, :user_id)
    refute Map.has_key?(meta, :email)
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

    assert {:registration_required, _conn, :github, data} = invoke_github_callback()

    assert data.provider == "github"
    assert data.email == ""
    assert data.is_verified == false
    assert data.email_from_provider == false
    assert data.github_user_id == 123
    assert data.name == "New User"
  end

  test "returns {:error, :general_error, provider, conn} when process_user fails" do
    user_info = %{"id" => 123}
    setup_pre_exchange_mocks()

    :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
      {:ok, :authed_client}
    end)

    :meck.expect(Client, :get_user_info, fn :authed_client, :github -> {:ok, user_info} end)

    :meck.expect(UserProcessor, :process_user, fn :github, ^user_info ->
      {:error, :invalid_user_info}
    end)

    assert {:error, :general_error, :github, _conn} = invoke_github_callback()
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

    test "returns {:registration_required, ...} with provider_uid param for new generic OAuth user" do
      user_info = %{"sub" => "new-user-789", "email" => "new-sso@example.com"}

      processed_user = %{
        email: "new-sso@example.com",
        provider_uid: "new-user-789",
        name: "New SSO",
        is_verified: true
      }

      enhanced_user = Map.put(processed_user, :email_from_provider, true)

      setup_oauth_pre_exchange_mocks()

      :meck.expect(Client, :exchange_code_for_token, fn :oauth_client, "code" ->
        {:ok, :authed_client}
      end)

      :meck.expect(Client, :get_user_info, fn :authed_client, :oauth -> {:ok, user_info} end)

      :meck.expect(UserProcessor, :process_user, fn :oauth, ^user_info ->
        {:ok, processed_user}
      end)

      :meck.expect(UserProcessor, :enhance_user_data, fn :oauth,
                                                         ^processed_user,
                                                         :authed_client ->
        enhanced_user
      end)

      :meck.expect(UserRegistration, :find_existing_user, fn :oauth, ^enhanced_user ->
        {:error, :not_found}
      end)

      :meck.expect(UserRegistration, :check_oauth_requirements, fn :oauth, ^enhanced_user ->
        :complete
      end)

      assert {:registration_required, _conn, :oauth, data} =
               FlowHandler.handle_oauth_callback(base_conn(), %{
                 code: "code",
                 state: "state",
                 provider: :oauth
               })

      assert data.provider == "oauth"
      assert data.provider_uid == "new-user-789"
      assert data.email == "new-sso@example.com"
    end
  end

  defp unload_if_loaded(module) do
    :meck.unload(module)
  rescue
    _error -> :ok
  end
end
