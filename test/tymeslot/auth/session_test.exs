defmodule Tymeslot.Auth.SessionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Phoenix.Socket.Broadcast
  alias Tymeslot.Auth.Session
  alias Tymeslot.Auth.UserSessionQueries
  alias TymeslotWeb.Endpoint

  import Plug.Conn, only: [get_session: 2, put_session: 3]
  import Tymeslot.Factory
  import Phoenix.ConnTest

  defp live_socket_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  describe "create_session/2" do
    test "stores session token in conn session" do
      user = insert(:user)
      {:ok, conn, _token} = Session.create_session(init_test_session(build_conn(), %{}), user)

      assert get_session(conn, :user_token)
    end

    test "stores session token in database" do
      user = insert(:user)
      {:ok, _conn, token} = Session.create_session(init_test_session(build_conn(), %{}), user)

      assert String.length(token) > 0
      assert UserSessionQueries.get_user_by_session_token(token)
    end

    test "session has 24-hour expiration" do
      user = insert(:user)
      {:ok, _conn, token} = Session.create_session(init_test_session(build_conn(), %{}), user)

      # Token should work now
      assert %{id: _id} = UserSessionQueries.get_user_by_session_token(token)
    end
  end

  describe "delete_session/1" do
    test "removes token from database" do
      user = insert(:user)
      {:ok, conn, token} = Session.create_session(init_test_session(build_conn(), %{}), user)

      Session.delete_session(conn)

      assert nil == UserSessionQueries.get_user_by_session_token(token)
    end

    test "clears conn session" do
      user = insert(:user)
      {:ok, conn, _token} = Session.create_session(init_test_session(build_conn(), %{}), user)

      updated_conn = Session.delete_session(conn)

      assert nil == Session.get_current_user_id(updated_conn)
    end

    test "force-disconnects the live socket bound to the revoked token" do
      user = insert(:user)
      {:ok, conn, token} = Session.create_session(init_test_session(build_conn(), %{}), user)

      Endpoint.subscribe(live_socket_topic(token))

      Session.delete_session(conn)

      assert_receive %Broadcast{event: "disconnect"}
    end
  end

  describe "revoke_all_sessions/1" do
    test "deletes every session for the user" do
      user = insert(:user)
      insert(:user_session, user: user, token: "tok-a")
      insert(:user_session, user: user, token: "tok-b")

      assert :ok == Session.revoke_all_sessions(user.id)

      assert nil == UserSessionQueries.get_user_by_session_token("tok-a")
      assert nil == UserSessionQueries.get_user_by_session_token("tok-b")
    end

    test "force-disconnects the live socket of every revoked session" do
      user = insert(:user)
      insert(:user_session, user: user, token: "tok-a")
      insert(:user_session, user: user, token: "tok-b")

      Endpoint.subscribe(live_socket_topic("tok-a"))
      Endpoint.subscribe(live_socket_topic("tok-b"))

      Session.revoke_all_sessions(user.id)

      assert_receive %Broadcast{topic: "users_sessions:" <> _a, event: "disconnect"}
      assert_receive %Broadcast{topic: "users_sessions:" <> _b, event: "disconnect"}
    end

    test "does not disconnect another user's sessions" do
      user = insert(:user)
      other = insert(:user)
      insert(:user_session, user: user, token: "mine")
      insert(:user_session, user: other, token: "theirs")

      Endpoint.subscribe(live_socket_topic("theirs"))

      Session.revoke_all_sessions(user.id)

      refute_receive %Broadcast{event: "disconnect"}
      assert UserSessionQueries.get_user_by_session_token("theirs")
    end
  end

  describe "get_current_user_id/1" do
    test "returns user ID for valid session" do
      user = insert(:user)
      {:ok, conn, _token} = Session.create_session(init_test_session(build_conn(), %{}), user)

      assert Session.get_current_user_id(conn) == user.id
    end

    test "returns nil for unauthenticated sessions" do
      conn = init_test_session(build_conn(), %{})

      assert Session.get_current_user_id(conn) == nil
    end

    test "returns nil for expired session token" do
      user = insert(:user)

      _expired_session =
        insert(:user_session,
          user: user,
          token: "expired-token-value",
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      conn =
        build_conn()
        |> init_test_session(%{})
        |> put_session(:user_token, "expired-token-value")

      assert Session.get_current_user_id(conn) == nil
    end
  end

  describe "get_unverified_user_from_session/1" do
    test "returns user data when valid and within 30 min" do
      timestamp = DateTime.to_unix(DateTime.utc_now())

      session = %{
        "unverified_user_id" => 123,
        "unverified_user_email" => "test@example.com",
        "unverified_session_timestamp" => timestamp
      }

      result = Session.get_unverified_user_from_session(session)

      assert result.id == 123
      assert result.email == "test@example.com"
      assert result.timestamp == timestamp
    end

    test "returns nil when expired (>30 min)" do
      old_timestamp = DateTime.to_unix(DateTime.utc_now()) - 1900

      session = %{
        "unverified_user_id" => 123,
        "unverified_user_email" => "test@example.com",
        "unverified_session_timestamp" => old_timestamp
      }

      assert nil == Session.get_unverified_user_from_session(session)
    end

    test "returns nil when missing fields" do
      assert nil == Session.get_unverified_user_from_session(%{})
      assert nil == Session.get_unverified_user_from_session(%{"unverified_user_id" => 123})

      assert nil ==
               Session.get_unverified_user_from_session(%{
                 "unverified_user_id" => 123,
                 "unverified_user_email" => "test@example.com"
               })
    end
  end

  describe "session_valid?/1" do
    test "returns true for recent timestamp" do
      timestamp = DateTime.to_unix(DateTime.utc_now())
      assert Session.session_valid?(timestamp)
    end

    test "returns false for expired timestamp" do
      timestamp = DateTime.to_unix(DateTime.utc_now()) - 1801
      refute Session.session_valid?(timestamp)
    end

    test "boundary: exactly 1800 seconds is still invalid" do
      timestamp = DateTime.to_unix(DateTime.utc_now()) - 1800
      refute Session.session_valid?(timestamp)
    end

    test "boundary: 1799 seconds is still valid" do
      timestamp = DateTime.to_unix(DateTime.utc_now()) - 1799
      assert Session.session_valid?(timestamp)
    end
  end
end
