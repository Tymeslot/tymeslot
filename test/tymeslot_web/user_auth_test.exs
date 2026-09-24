defmodule TymeslotWeb.UserAuthTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Phoenix.Socket.Broadcast
  alias Tymeslot.Auth.UserSessionQueries
  alias Tymeslot.Security.Token
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.UserAuth

  import Plug.Conn, only: [get_session: 2]
  import Tymeslot.Factory
  import Phoenix.ConnTest

  # The real socket topic is derived from the token *hash*, so pass the plaintext
  # token here and hash it to reconstruct the same topic.
  defp live_socket_topic(token),
    do: "users_sessions:#{Base.url_encode64(Token.hash_token(token))}"

  describe "create_session/2" do
    test "stores session token in conn session" do
      user = insert(:user)
      {:ok, conn, _token} = UserAuth.create_session(init_test_session(build_conn(), %{}), user)

      assert get_session(conn, :user_token)
    end

    test "stores session token in database" do
      user = insert(:user)
      {:ok, _conn, token} = UserAuth.create_session(init_test_session(build_conn(), %{}), user)

      assert String.length(token) > 0
      assert UserSessionQueries.get_user_by_session_token(token)
    end

    test "signing in on a conn that already carries a session revokes that session" do
      user = insert(:user)
      {:ok, conn, old_token} = UserAuth.create_session(init_test_session(build_conn(), %{}), user)

      Endpoint.subscribe(live_socket_topic(old_token))

      {:ok, conn, new_token} = UserAuth.create_session(conn, user)

      assert nil == UserSessionQueries.get_user_by_session_token(old_token)
      assert_receive %Broadcast{event: "disconnect"}
      assert %{id: user_id} = UserSessionQueries.get_user_by_session_token(new_token)
      assert user_id == user.id
      assert get_session(conn, :user_token) == new_token
    end

    test "leaves sessions carried by other connections alone" do
      user = insert(:user)

      {:ok, _conn, other_token} =
        UserAuth.create_session(init_test_session(build_conn(), %{}), user)

      {:ok, _conn, _token} = UserAuth.create_session(init_test_session(build_conn(), %{}), user)

      assert UserSessionQueries.get_user_by_session_token(other_token)
    end
  end

  describe "delete_session/1" do
    test "removes token from database" do
      user = insert(:user)
      {:ok, conn, token} = UserAuth.create_session(init_test_session(build_conn(), %{}), user)

      UserAuth.delete_session(conn)

      assert nil == UserSessionQueries.get_user_by_session_token(token)
    end

    test "clears conn session" do
      user = insert(:user)
      {:ok, conn, _token} = UserAuth.create_session(init_test_session(build_conn(), %{}), user)

      updated_conn = UserAuth.delete_session(conn)

      assert nil == get_session(updated_conn, :user_token)
    end

    test "force-disconnects the live socket bound to the revoked token" do
      user = insert(:user)
      {:ok, conn, token} = UserAuth.create_session(init_test_session(build_conn(), %{}), user)

      Endpoint.subscribe(live_socket_topic(token))

      UserAuth.delete_session(conn)

      assert_receive %Broadcast{event: "disconnect"}
    end
  end

  describe "user_from_session/1" do
    test "returns the user for a valid session token" do
      user = insert(:user)
      {:ok, _conn, token} = UserAuth.create_session(init_test_session(build_conn(), %{}), user)

      assert %{id: user_id} = UserAuth.user_from_session(%{"user_token" => token})
      assert user_id == user.id
    end

    test "returns nil for a token that matches no session" do
      assert UserAuth.user_from_session(%{"user_token" => "nonexistent-token"}) == nil
    end

    test "returns nil when the session carries no token" do
      assert UserAuth.user_from_session(%{}) == nil
    end

    test "returns nil for an expired session token" do
      user = insert(:user)

      _expired_session =
        insert(:user_session,
          user: user,
          token_hash: Token.hash_token("expired-token-value"),
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      assert UserAuth.user_from_session(%{"user_token" => "expired-token-value"}) == nil
    end
  end

  describe "unverified_user_from_session/1" do
    test "returns user data when valid and within 30 min" do
      timestamp = DateTime.to_unix(DateTime.utc_now())

      session = %{
        "unverified_user_id" => 123,
        "unverified_user_email" => "test@example.com",
        "unverified_session_timestamp" => timestamp
      }

      result = UserAuth.unverified_user_from_session(session)

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

      assert nil == UserAuth.unverified_user_from_session(session)
    end

    test "returns nil when missing fields" do
      assert nil == UserAuth.unverified_user_from_session(%{})
      assert nil == UserAuth.unverified_user_from_session(%{"unverified_user_id" => 123})

      assert nil ==
               UserAuth.unverified_user_from_session(%{
                 "unverified_user_id" => 123,
                 "unverified_user_email" => "test@example.com"
               })
    end
  end

  describe "unverified_user_from_session/1 freshness" do
    defp unverified_session(age_seconds) do
      %{
        "unverified_user_id" => 123,
        "unverified_user_email" => "test@example.com",
        "unverified_session_timestamp" => DateTime.to_unix(DateTime.utc_now()) - age_seconds
      }
    end

    test "boundary: 1799 seconds is still valid" do
      assert %{id: 123} = UserAuth.unverified_user_from_session(unverified_session(1799))
    end

    test "boundary: exactly 1800 seconds is no longer valid" do
      assert nil == UserAuth.unverified_user_from_session(unverified_session(1800))
    end
  end
end
