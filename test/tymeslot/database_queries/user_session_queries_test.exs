defmodule Tymeslot.DatabaseQueries.UserSessionQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.UserSessionQueries

  describe "create_session/3" do
    test "creates session with valid attributes" do
      user = insert(:user)
      token = "session_token_123"
      expires_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 72, :hour), :second)

      assert {:ok, session} = UserSessionQueries.create_session(user.id, token, expires_at)
      assert session.user_id == user.id
      assert session.token == token
      assert session.expires_at == expires_at
    end

    test "returns error with invalid attributes" do
      assert {:error, changeset} = UserSessionQueries.create_session(nil, nil, nil)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
      assert "can't be blank" in errors_on(changeset).token
      assert "can't be blank" in errors_on(changeset).expires_at
    end

    test "returns error with duplicate token" do
      user1 = insert(:user)
      user2 = insert(:user)
      token = "duplicate_token"
      expires_at = DateTime.add(DateTime.utc_now(), 72, :hour)

      # Create first session successfully
      assert {:ok, _session1} = UserSessionQueries.create_session(user1.id, token, expires_at)

      # Attempt to create second session with same token
      assert {:error, changeset} = UserSessionQueries.create_session(user2.id, token, expires_at)
      assert "has already been taken" in errors_on(changeset).token
    end
  end

  describe "get_user_by_session_token/1" do
    test "returns user when session token exists and is not expired" do
      user = insert(:user, email: "test@example.com", name: "Test User")
      token = "valid_token_123"
      expires_at = DateTime.add(DateTime.utc_now(), 72, :hour)

      assert {:ok, _session} = UserSessionQueries.create_session(user.id, token, expires_at)

      assert fetched_user = UserSessionQueries.get_user_by_session_token(token)
      assert fetched_user.id == user.id
      assert fetched_user.email == user.email
      assert fetched_user.name == user.name
    end

    test "returns nil when session token is expired" do
      user = insert(:user)
      token = "expired_token_123"
      create_session!(user, token, -1)

      assert nil == UserSessionQueries.get_user_by_session_token(token)
    end

    test "works with multiple sessions for same user" do
      user = insert(:user)
      token1 = "token_1"
      token2 = "token_2"

      create_session!(user, token1)
      create_session!(user, token2)

      assert fetched_user1 = UserSessionQueries.get_user_by_session_token(token1)
      assert fetched_user2 = UserSessionQueries.get_user_by_session_token(token2)
      assert fetched_user1.id == user.id
      assert fetched_user2.id == user.id
    end
  end

  describe "delete_user_sessions/1" do
    test "deletes all sessions for a user" do
      user = insert(:user)
      token1 = "token_1"
      token2 = "token_2"

      create_session!(user, token1)
      create_session!(user, token2)

      # Verify sessions exist
      assert UserSessionQueries.get_user_by_session_token(token1)
      assert UserSessionQueries.get_user_by_session_token(token2)

      # Delete all sessions for user
      assert {2, nil} = UserSessionQueries.delete_user_sessions(user.id)

      # Verify sessions are deleted
      assert nil == UserSessionQueries.get_user_by_session_token(token1)
      assert nil == UserSessionQueries.get_user_by_session_token(token2)
    end

    test "returns 0 when user has no sessions" do
      user = insert(:user)
      assert {0, nil} = UserSessionQueries.delete_user_sessions(user.id)
    end

    test "only deletes sessions for specified user" do
      user1 = insert(:user)
      user2 = insert(:user)
      token1 = "token_1"
      token2 = "token_2"

      create_session!(user1, token1)
      create_session!(user2, token2)

      # Delete sessions for user1 only
      assert {1, nil} = UserSessionQueries.delete_user_sessions(user1.id)

      # Verify only user1's session is deleted
      assert nil == UserSessionQueries.get_user_by_session_token(token1)
      assert UserSessionQueries.get_user_by_session_token(token2)
    end

    test "handles non-existent user" do
      assert {0, nil} = UserSessionQueries.delete_user_sessions(999_999)
    end
  end

  describe "delete_session_by_token/1" do
    test "deletes session by token" do
      user = insert(:user)
      token = "session_token_123"

      create_session!(user, token)

      # Verify session exists
      assert UserSessionQueries.get_user_by_session_token(token)

      # Delete session by token
      assert {1, nil} = UserSessionQueries.delete_session_by_token(token)

      # Verify session is deleted
      assert nil == UserSessionQueries.get_user_by_session_token(token)
    end

    test "only deletes session with matching token" do
      user = insert(:user)
      token1 = "token_1"
      token2 = "token_2"

      create_session!(user, token1)
      create_session!(user, token2)

      # Delete only token1
      assert {1, nil} = UserSessionQueries.delete_session_by_token(token1)

      # Verify only token1 is deleted
      assert nil == UserSessionQueries.get_user_by_session_token(token1)
      assert UserSessionQueries.get_user_by_session_token(token2)
    end
  end

  describe "cleanup_expired_sessions/0" do
    test "deletes expired sessions" do
      user = insert(:user)

      # Create expired session
      expired_token = "expired_token"
      create_session!(user, expired_token, -1)

      valid_token = "valid_token"
      create_session!(user, valid_token)

      # Cleanup expired sessions
      assert {1, nil} = UserSessionQueries.cleanup_expired_sessions()

      # Verify only expired session is deleted
      assert nil == UserSessionQueries.get_user_by_session_token(expired_token)
      assert UserSessionQueries.get_user_by_session_token(valid_token)
    end

    test "handles multiple expired sessions" do
      user1 = insert(:user)
      user2 = insert(:user)
      create_session!(user1, "expired_1", -1)

      create_session!(user2, "expired_2", -1)

      assert {2, nil} = UserSessionQueries.cleanup_expired_sessions()

      # Verify both sessions are deleted
      assert nil == UserSessionQueries.get_user_by_session_token("expired_1")
      assert nil == UserSessionQueries.get_user_by_session_token("expired_2")
    end

    test "works when no sessions exist" do
      assert {0, nil} = UserSessionQueries.cleanup_expired_sessions()
    end
  end

  defp create_session!(user, token, hours_from_now \\ 72) do
    expires_at = DateTime.add(DateTime.utc_now(), hours_from_now, :hour)
    {:ok, session} = UserSessionQueries.create_session(user.id, token, expires_at)
    session
  end
end
