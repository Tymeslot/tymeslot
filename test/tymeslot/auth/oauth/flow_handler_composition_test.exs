defmodule Tymeslot.Auth.OAuth.FlowHandlerCompositionTest do
  @moduledoc """
  DB-backed composition coverage for
  `Tymeslot.Auth.OAuth.FlowHandler.handle_oauth_callback/2`.

  The historical `flow_handler_test.exs` uses `:meck` to stub six internal
  modules (State, URLs, UserProcessor, UserRegistration, Session, Client).
  Per the project's "mock only at system boundaries" rule, this file
  exercises the real modules end-to-end and mocks only the `Client` module
  — the layer that talks to the external OAuth provider over HTTP.

  The flow under test:

    state validation → token exchange → user info fetch →
    user normalisation → existing-user lookup (or registration-required) →
    session creation

  Each test drives it from a real `Plug.Conn` with a real session and a
  real user row, asserting on the tagged tuple the handler returns.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :integration

  import Ecto.Query
  import Tymeslot.Factory

  alias Plug.Conn
  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.OAuth.{Client, FlowHandler, State}
  alias Tymeslot.Auth.UserSessionSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token
  alias Tymeslot.Test.LogCapture

  setup do
    :meck.new(Client, [:passthrough])
    on_exit(fn -> safely_unload(Client) end)
    :ok
  end

  describe "state validation" do
    test "returns {:error, :invalid_state, conn} when session has no state" do
      conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})

      assert {:error, :invalid_state, ^conn} =
               FlowHandler.handle_oauth_callback(conn, %{
                 code: "any-code",
                 state: "mismatched-state",
                 provider: :github
               })
    end

    test "returns {:error, :invalid_state, conn} when state does not match" do
      {conn, _real_state} = conn_with_fresh_state()

      assert {:error, :invalid_state, _conn} =
               FlowHandler.handle_oauth_callback(conn, %{
                 code: "code",
                 state: "not-the-real-state",
                 provider: :github
               })
    end
  end

  describe "existing-user login" do
    test "returns {:ok, conn, :github} and creates a real session row for a known GitHub user" do
      # Use a plain integer string so normalize_github_id/1 succeeds and the
      # get_user_by_github_id branch is exercised — not the email-fallback path.
      github_id = "#{System.unique_integer([:positive])}"
      user = insert(:user, provider: "github", github_user_id: github_id)

      # Deliberately use a different email in the OAuth stub so the test cannot
      # pass via the email-fallback branch; only the GitHub-ID lookup can match.
      stub_email = "oauth-stub-#{System.unique_integer([:positive])}@example.com"

      stub_client_success(:github, %{
        "id" => github_id,
        "email" => stub_email,
        "name" => user.name
      })

      {conn, state} = conn_with_fresh_state()

      assert {:ok, result_conn, :github} =
               FlowHandler.handle_oauth_callback(conn, %{
                 code: "valid-code",
                 state: state,
                 provider: :github
               })

      # Real Session.create_session inserts a row keyed on the user id.
      sessions =
        Repo.all(
          from s in UserSessionSchema,
            where: s.user_id == ^user.id
        )

      assert [session_row] = sessions
      # The conn carries the plaintext token; the row stores only its hash.
      assert Token.hash_token(Conn.get_session(result_conn, :user_token)) ==
               session_row.token_hash

      # The session row is for the correct user — matched via GitHub ID, not email.
      assert session_row.user_id == user.id
    end

    test "returns {:ok, conn, :google} for a known Google user" do
      google_id = "google-#{System.unique_integer([:positive])}"
      user = insert(:user, provider: "google", google_user_id: google_id)

      stub_client_success(:google, %{
        "id" => google_id,
        "email" => user.email,
        "name" => user.name
      })

      {conn, state} = conn_with_fresh_state()

      assert {:ok, _conn, :google} =
               FlowHandler.handle_oauth_callback(conn, %{
                 code: "valid-code",
                 state: state,
                 provider: :google
               })
    end

    test "returns {:ok, conn, :oauth} for a known generic-OAuth user keyed on provider_uid" do
      provider_uid = "sub-#{System.unique_integer([:positive])}"
      user = insert(:user, provider: "oauth", provider_uid: provider_uid)

      stub_client_success(:oauth, %{
        "sub" => provider_uid,
        "email" => user.email,
        "name" => user.name
      })

      {conn, state} = conn_with_fresh_state()

      assert {:ok, _conn, :oauth} =
               FlowHandler.handle_oauth_callback(conn, %{
                 code: "valid-code",
                 state: state,
                 provider: :oauth
               })
    end
  end

  describe "new user — registration required" do
    test "returns {:registration_required, conn, :github, params} when no user matches" do
      new_github_id = "new-gh-#{System.unique_integer([:positive])}"
      new_email = "new-gh-#{System.unique_integer([:positive])}@example.com"

      stub_client_success(:github, %{
        "id" => new_github_id,
        "email" => new_email,
        "name" => "Brand New"
      })

      {conn, state} = conn_with_fresh_state()

      assert {:registration_required, _conn, :github, params} =
               FlowHandler.handle_oauth_callback(conn, %{
                 code: "valid-code",
                 state: state,
                 provider: :github
               })

      assert params.email == new_email
      assert params.github_user_id == new_github_id
      assert params.provider == "github"
      assert params.email_from_provider == true
    end
  end

  describe "registration disabled" do
    test "returns {:error, :registration_disabled, :github, conn} when a new user arrives" do
      original = Application.get_env(:tymeslot, :registration_enabled)
      Application.put_env(:tymeslot, :registration_enabled, false)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:tymeslot, :registration_enabled),
          else: Application.put_env(:tymeslot, :registration_enabled, original)
      end)

      stub_client_success(:github, %{
        "id" => "unseen-#{System.unique_integer([:positive])}",
        "email" => "unseen-#{System.unique_integer([:positive])}@example.com",
        "name" => "Should Be Rejected"
      })

      {conn, state} = conn_with_fresh_state()

      assert {:error, :registration_disabled, :github, _conn} =
               FlowHandler.handle_oauth_callback(conn, %{
                 code: "valid-code",
                 state: state,
                 provider: :github
               })

      # And no user was created as a side-effect.
      assert Repo.aggregate(Tymeslot.Auth.UserSchema, :count, :id) == 0
    end

    test "audits a social_auth_failure with error_reason \"registration_disabled\"" do
      original = Application.get_env(:tymeslot, :registration_enabled)
      Application.put_env(:tymeslot, :registration_enabled, false)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:tymeslot, :registration_enabled),
          else: Application.put_env(:tymeslot, :registration_enabled, original)
      end)

      new_email = "unseen-#{System.unique_integer([:positive])}@example.com"

      stub_client_success(:github, %{
        "id" => "unseen-#{System.unique_integer([:positive])}",
        "email" => new_email,
        "name" => "Should Be Rejected"
      })

      {conn, state} = conn_with_fresh_state()

      LogCapture.with_capture([logger_level: :info], fn ->
        assert {:error, :registration_disabled, :github, _conn} =
                 FlowHandler.handle_oauth_callback(conn, %{
                   code: "valid-code",
                   state: state,
                   provider: :github
                 })
      end)

      assert [event] =
               LogCapture.drain()
               |> Enum.map(&LogCapture.user_metadata/1)
               |> Enum.filter(
                 &(&1[:event_type] in ["social_auth_success", "social_auth_failure"])
               )

      assert event.event_type == "social_auth_failure"
      assert event.provider == "github"
    end
  end

  describe "provider errors" do
    test "returns {:error, :oauth_error, :github, conn} on OAuth2 protocol failure" do
      :meck.expect(Client, :build, fn :github, _url, _token -> :fake_client end)

      :meck.expect(Client, :exchange_code_for_token, fn :fake_client, _code ->
        {:error, %OAuth2.Error{reason: "access_denied"}}
      end)

      {conn, state} = conn_with_fresh_state()

      assert {:error, :oauth_error, :github, _conn} =
               FlowHandler.handle_oauth_callback(conn, %{
                 code: "code",
                 state: state,
                 provider: :github
               })
    end

    test "returns {:error, :general_error, :github, conn} when get_user_info fails" do
      :meck.expect(Client, :build, fn :github, _url, _token -> :fake_client end)
      :meck.expect(Client, :exchange_code_for_token, fn :fake_client, _code -> {:ok, :authed} end)
      :meck.expect(Client, :get_user_info, fn :authed, :github -> {:error, :network} end)

      {conn, state} = conn_with_fresh_state()

      assert {:error, :general_error, :github, _conn} =
               FlowHandler.handle_oauth_callback(conn, %{
                 code: "code",
                 state: state,
                 provider: :github
               })
    end
  end

  # --- Helpers ---

  defp conn_with_fresh_state do
    conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
    State.generate_and_store_state(conn)
  end

  defp stub_client_success(provider, user_info) do
    :meck.expect(Client, :build, fn ^provider, _url, _token -> :fake_client end)
    :meck.expect(Client, :exchange_code_for_token, fn :fake_client, _code -> {:ok, :authed} end)
    :meck.expect(Client, :get_user_info, fn :authed, ^provider -> {:ok, user_info} end)
  end

  defp safely_unload(module) do
    :meck.unload(module)
  rescue
    _error -> :ok
  end
end
