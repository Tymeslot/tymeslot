defmodule Tymeslot.Auth.OAuth.FlowHandlerTest do
  @moduledoc """
  DB-backed coverage for `Tymeslot.Auth.OAuth.FlowHandler.handle_oauth_callback/2`:

    state validation -> token exchange -> user info -> normalisation ->
    account lookup -> session, verify screen, or registration

  Only the provider's HTTP endpoints are stubbed
  (`Tymeslot.Test.OAuthProviderStub`); state, lookups and sessions are real.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :integration

  import Ecto.Query
  import Tymeslot.Test.OAuthProviderStub

  alias Plug.Conn
  alias Plug.Test, as: PlugTest
  alias Req.Test, as: ReqTest
  alias Tymeslot.Auth.OAuth.{FlowHandler, State}
  alias Tymeslot.Auth.{Session, UserSchema, UserSessionSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token
  alias Tymeslot.Test.LogCapture

  setup :setup_providers

  describe "state validation" do
    test "rejects a callback on a session that never started a flow" do
      conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})

      assert {:error, :invalid_state, _conn} = callback(conn, :github, "any-state")
    end

    test "rejects a state other than the one issued, and audits it" do
      {conn, _flow} = fresh_flow()

      capture_at_info(fn ->
        assert {:error, :invalid_state, _conn} = callback(conn, :github, "not-the-real-state")
      end)

      assert [%{event_type: "social_auth_failure", provider: "github", email_masked: nil}] =
               social_auth_events()
    end
  end

  describe "existing-user login" do
    test "signs a known GitHub user in by GitHub ID, not email, and audits it" do
      user = insert(:user, provider: "github", github_user_id: "4242", email: "owner@example.com")

      stub_github(%{"id" => 4242}, [
        %{"email" => "other@example.com", "primary" => true, "verified" => true}
      ])

      {conn, flow} = fresh_flow()

      result =
        capture_at_info(fn -> callback(conn, :github, flow.state) end)

      assert {:ok, result_conn, :github} = result
      assert [session_row] = Repo.all(from s in UserSessionSchema, where: s.user_id == ^user.id)

      assert Token.hash_token(Conn.get_session(result_conn, :user_token)) ==
               session_row.token_hash

      assert [event] = social_auth_events()
      assert event.event_type == "social_auth_success"
      assert event.email_masked == "o***@example.com"
      refute inspect(event) =~ "owner@example.com"
    end

    test "signs a known Google user in" do
      insert(:user, provider: "google", google_user_id: "g-77")
      stub_google(%{"id" => "g-77", "email" => "g@example.com", "verified_email" => true})
      {conn, flow} = fresh_flow()

      assert {:ok, _conn, :google} = callback(conn, :google, flow.state)
    end

    test "signs a known SSO user in by provider_uid" do
      insert(:user, provider: "oauth", provider_uid: "sub-9")
      stub_sso(%{"sub" => "sub-9", "email" => "s@example.com", "email_verified" => true})
      {conn, flow} = fresh_flow()

      assert {:ok, _conn, :oauth} = callback(conn, :oauth, flow.state)
    end

    test "emits an anonymous login_completed telemetry event" do
      insert(:user, provider: "github", github_user_id: "4243")
      stub_github(%{"id" => 4243}, [])
      {conn, flow} = fresh_flow()

      test_pid = self()
      handler_id = {__MODULE__, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:tymeslot, :auth, :login_completed],
        fn _event, measurements, meta, _config ->
          send(test_pid, {:login_completed, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _conn, :github} = callback(conn, :github, flow.state)
      assert_receive {:login_completed, %{count: 1}, meta}
      assert meta == %{method: "oauth", provider: "github"}
    end

    test "an unverified account gets no session" do
      user = insert(:user, provider: "github", github_user_id: "4244", verified_at: nil)
      stub_github(%{"id" => 4244}, [])
      {conn, flow} = fresh_flow()

      assert {:verification_required, result_conn, :github, :sent} =
               callback(conn, :github, flow.state)

      assert Conn.get_session(result_conn, :user_token) == nil
      assert Conn.get_session(result_conn, :unverified_user_id) == user.id
      assert Repo.all(from s in UserSessionSchema, where: s.user_id == ^user.id) == []
    end

    test "an unverified account becomes verified when the provider vouches for its email" do
      user =
        insert(:user,
          provider: "github",
          github_user_id: "4247",
          email: "owner@example.com",
          verified_at: nil
        )

      stub_github(%{"id" => 4247}, [
        %{"email" => "Owner@Example.com", "primary" => true, "verified" => true}
      ])

      {conn, flow} = fresh_flow()

      assert {:ok, result_conn, :github} = callback(conn, :github, flow.state)
      assert Conn.get_session(result_conn, :user_token)
      assert Repo.reload!(user).verified_at
    end

    test "an unverified account whose provider vouches for another address stays unverified" do
      user =
        insert(:user,
          provider: "github",
          github_user_id: "4248",
          email: "typed@example.com",
          verified_at: nil
        )

      stub_github(%{"id" => 4248}, [
        %{"email" => "someone-else@example.com", "primary" => true, "verified" => true}
      ])

      {conn, flow} = fresh_flow()

      assert {:verification_required, _conn, :github, :sent} = callback(conn, :github, flow.state)
      assert Repo.reload!(user).verified_at == nil
    end

    test "reports and audits a session that could not be created" do
      insert(:user, provider: "github", github_user_id: "4245", email: "s@example.com")
      stub_github(%{"id" => 4245}, [])
      {conn, flow} = fresh_flow()

      # The one internal seam left: nothing a test can arrange makes a real
      # session insert fail for an account that exists.
      :meck.new(Session, [:passthrough])
      on_exit(fn -> :meck.unload() end)
      :meck.expect(Session, :create_session, fn _conn, _user -> {:error, :db_error, "failed"} end)

      result = capture_at_info(fn -> callback(conn, :github, flow.state) end)

      assert {:error, :session_failed, :github, _conn} = result

      assert [%{event_type: "social_auth_failure", email_masked: "s***@example.com"}] =
               social_auth_events()
    end

    test "refuses a login whose email belongs to an account from another provider" do
      google_account =
        insert(:user, email: "taken@example.com", provider: "google", google_user_id: "g-1")

      stub_github(%{"id" => 4246}, [
        %{"email" => "taken@example.com", "primary" => true, "verified" => true}
      ])

      {conn, flow} = fresh_flow()

      result = capture_at_info(fn -> callback(conn, :github, flow.state) end)

      assert {:error, :email_already_taken, :github, _conn} = result
      assert [%{event_type: "social_auth_failure"}] = social_auth_events()
      assert Repo.get!(UserSchema, google_account.id).github_user_id == nil
    end
  end

  describe "new user" do
    test "routes to registration with the provider's verified email, unaudited" do
      stub_github(%{"id" => 5150, "name" => "Brand New"}, [
        %{"email" => "new@example.com", "primary" => true, "verified" => true}
      ])

      {conn, flow} = fresh_flow()

      result = capture_at_info(fn -> callback(conn, :github, flow.state) end)

      assert {:registration_required, _conn, :github, data} = result
      assert data.email == "new@example.com"
      assert data.email_from_provider == true
      assert data.provider_uid == "5150"
      assert data.provider == "github"
      assert social_auth_events() == []
    end

    test "leaves the email for the user to type when GitHub has no verified one" do
      stub_github(%{"id" => 5151, "email" => "public@example.com"}, [])
      {conn, flow} = fresh_flow()

      assert {:registration_required, _conn, :github, data} = callback(conn, :github, flow.state)
      assert data.email == ""
      assert data.email_from_provider == false
    end

    test "is refused, and audited, while registration is disabled" do
      original = Application.get_env(:tymeslot, :registration_enabled)
      Application.put_env(:tymeslot, :registration_enabled, false)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:tymeslot, :registration_enabled),
          else: Application.put_env(:tymeslot, :registration_enabled, original)
      end)

      stub_sso(%{"sub" => "sub-new", "email" => "n@example.com", "email_verified" => true})
      {conn, flow} = fresh_flow()

      result = capture_at_info(fn -> callback(conn, :oauth, flow.state) end)

      assert {:error, :registration_disabled, :oauth, _conn} = result
      assert [%{event_type: "social_auth_failure", provider: "oauth"}] = social_auth_events()
      assert Repo.aggregate(UserSchema, :count) == 0
    end
  end

  describe "provider errors" do
    test "a transport failure on the token exchange is a general error" do
      stub_provider(%{
        "/login/oauth/access_token" => &ReqTest.transport_error(&1, :econnrefused)
      })

      {conn, flow} = fresh_flow()

      assert {:error, :general_error, :github, _conn} = callback(conn, :github, flow.state)
    end

    test "a refused token exchange is an OAuth error, audited without the OAuth code" do
      stub_provider(%{
        "/login/oauth/access_token" => &Conn.send_resp(&1, 401, ~s({"error":"bad_code"}))
      })

      {conn, flow} = fresh_flow()

      result = capture_at_info(fn -> callback(conn, :github, flow.state) end)

      assert {:error, :oauth_error, :github, _conn} = result
      assert [event] = social_auth_events()
      assert event.event_type == "social_auth_failure"
      refute inspect(event) =~ "provider-code"
    end

    test "GitHub answering a bad code with 200 and an error is an OAuth error" do
      stub_provider(%{"/login/oauth/access_token" => %{"error" => "bad_verification_code"}})
      {conn, flow} = fresh_flow()

      assert {:error, :oauth_error, :github, _conn} = callback(conn, :github, flow.state)
    end

    test "userinfo without an identifier is a general error" do
      stub_sso(%{"email" => "no-sub@example.com"})
      {conn, flow} = fresh_flow()

      assert {:error, :general_error, :oauth, _conn} = callback(conn, :oauth, flow.state)
    end
  end

  defp fresh_flow do
    conn = PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
    State.generate_and_store_state(conn)
  end

  defp callback(conn, provider, state) do
    FlowHandler.handle_oauth_callback(conn, %{
      code: "provider-code",
      state: state,
      provider: provider
    })
  end

  # SecurityLogger emits at :info while config/test.exs pins the primary level
  # to :warning, so it has to come down for the duration. Safe: async: false.
  defp capture_at_info(fun), do: LogCapture.with_capture([logger_level: :info], fun)

  defp social_auth_events do
    LogCapture.drain()
    |> Enum.map(&LogCapture.user_metadata/1)
    |> Enum.filter(&(&1[:event_type] in ["social_auth_success", "social_auth_failure"]))
  end
end
