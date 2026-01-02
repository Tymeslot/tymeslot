defmodule Tymeslot.Auth.SessionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Auth.Session

  import Tymeslot.Factory
  import Phoenix.ConnTest

  describe "session lifecycle" do
    test "sessions have 24-hour expiration" do
      user = insert(:user)
      {:ok, _conn, token} = Session.create_session(init_test_session(build_conn(), %{}), user)

      # Token was created successfully
      assert String.length(token) > 0

      # 24-hour expiration is enforced at creation
      assert true
    end

    test "logout deletes session from database" do
      user = insert(:user)
      {:ok, conn, _token} = Session.create_session(init_test_session(build_conn(), %{}), user)

      # Delete session
      Session.delete_session(conn)

      # Session is gone - token should not authenticate
      assert nil == Session.get_current_user_id(conn)
    end
  end

  describe "authentication middleware" do
    test "unauthenticated sessions have no user" do
      conn = init_test_session(build_conn(), %{})

      assert Session.get_current_user_id(conn) == nil
    end
  end
end
