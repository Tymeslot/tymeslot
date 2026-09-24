defmodule Tymeslot.Auth.SessionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Phoenix.Socket.Broadcast
  alias Tymeslot.Auth.Session
  alias Tymeslot.Auth.UserSessionQueries
  alias Tymeslot.Auth.UserSessionSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token
  alias TymeslotWeb.Endpoint

  import Tymeslot.Factory

  # The real socket topic is derived from the token *hash*, so pass the plaintext
  # token here and hash it to reconstruct the same topic.
  defp live_socket_topic(token),
    do: "users_sessions:#{Base.url_encode64(Token.hash_token(token))}"

  # Makes a session look as though it had been created `hours` ago, by rewinding
  # the expiry that `create_session/2` stamped on it. Deliberately relative: the
  # test asserts how long a session lasts without restating the lifetime.
  defp age_session(token, hours) do
    session = Repo.get_by!(UserSessionSchema, token_hash: Token.hash_token(token))

    session
    |> change(expires_at: DateTime.add(session.expires_at, -hours, :hour))
    |> Repo.update!()
  end

  describe "create_session/2" do
    test "stores the session and returns its token" do
      user = insert(:user)
      {:ok, token} = Session.create_session(user.id)

      assert String.length(token) > 0
      assert %{id: user_id} = UserSessionQueries.get_user_by_session_token(token)
      assert user_id == user.id
    end

    test "a session still resolves after 23 hours but no longer after 25" do
      user = insert(:user)
      {:ok, recent_token} = Session.create_session(user.id)
      {:ok, stale_token} = Session.create_session(user.id)

      age_session(recent_token, 23)
      age_session(stale_token, 25)

      assert %{id: _id} = UserSessionQueries.get_user_by_session_token(recent_token)
      assert nil == UserSessionQueries.get_user_by_session_token(stale_token)
    end

    test "revokes the session it replaces and disconnects its socket" do
      user = insert(:user)
      {:ok, old_token} = Session.create_session(user.id)

      Endpoint.subscribe(live_socket_topic(old_token))

      {:ok, new_token} = Session.create_session(user.id, replacing: old_token)

      assert nil == UserSessionQueries.get_user_by_session_token(old_token)
      assert_receive %Broadcast{event: "disconnect"}
      assert %{id: _id} = UserSessionQueries.get_user_by_session_token(new_token)
    end

    test "leaves the user's other sessions alone" do
      user = insert(:user)
      {:ok, other_token} = Session.create_session(user.id)
      {:ok, _token} = Session.create_session(user.id)

      assert UserSessionQueries.get_user_by_session_token(other_token)
    end

    test "records the login as the user's last activity" do
      user = insert(:user)
      assert is_nil(user.last_active_at)

      {:ok, _token} = Session.create_session(user.id)

      assert %DateTime{} = Repo.reload!(user).last_active_at
    end
  end

  describe "live_socket_id/1" do
    test "is the topic revoking the session broadcasts on" do
      {:ok, token} = Session.create_session(insert(:user).id)

      assert Session.live_socket_id(token) == live_socket_topic(token)
    end
  end

  describe "delete_session/2" do
    test "removes the session and disconnects its socket" do
      {:ok, token} = Session.create_session(insert(:user).id)
      Endpoint.subscribe(live_socket_topic(token))

      assert :ok == Session.delete_session(token)

      assert nil == UserSessionQueries.get_user_by_session_token(token)
      assert_receive %Broadcast{event: "disconnect"}
    end

    test "is a no-op without a token" do
      assert :ok == Session.delete_session(nil)
    end
  end

  describe "get_user_by_token/1" do
    test "returns the user for a live session token" do
      user = insert(:user)
      {:ok, token} = Session.create_session(user.id)

      assert %{id: user_id} = Session.get_user_by_token(token)
      assert user_id == user.id
    end

    test "returns nil for an unknown or missing token" do
      assert nil == Session.get_user_by_token("nonexistent-token")
      assert nil == Session.get_user_by_token(nil)
    end
  end

  describe "revoke_all_sessions/1" do
    test "deletes every session for the user" do
      user = insert(:user)
      insert(:user_session, user: user, token_hash: Token.hash_token("tok-a"))
      insert(:user_session, user: user, token_hash: Token.hash_token("tok-b"))

      assert :ok == Session.revoke_all_sessions(user.id)

      assert nil == UserSessionQueries.get_user_by_session_token("tok-a")
      assert nil == UserSessionQueries.get_user_by_session_token("tok-b")
    end

    test "force-disconnects the live socket of every revoked session" do
      user = insert(:user)
      insert(:user_session, user: user, token_hash: Token.hash_token("tok-a"))
      insert(:user_session, user: user, token_hash: Token.hash_token("tok-b"))

      topic_a = live_socket_topic("tok-a")
      topic_b = live_socket_topic("tok-b")

      Endpoint.subscribe(topic_a)
      Endpoint.subscribe(topic_b)

      Session.revoke_all_sessions(user.id)

      assert_receive %Broadcast{topic: ^topic_a, event: "disconnect"}
      assert_receive %Broadcast{topic: ^topic_b, event: "disconnect"}
    end

    test "does not disconnect another user's sessions" do
      user = insert(:user)
      other = insert(:user)
      insert(:user_session, user: user, token_hash: Token.hash_token("mine"))
      insert(:user_session, user: other, token_hash: Token.hash_token("theirs"))

      Endpoint.subscribe(live_socket_topic("theirs"))

      Session.revoke_all_sessions(user.id)

      refute_receive %Broadcast{event: "disconnect"}
      assert UserSessionQueries.get_user_by_session_token("theirs")
    end
  end
end
