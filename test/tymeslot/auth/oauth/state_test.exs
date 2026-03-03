defmodule Tymeslot.Auth.OAuth.StateTest do
  use ExUnit.Case, async: true
  @moduletag :auth

  alias Tymeslot.Auth.OAuth.State

  defp build_conn do
    :get
    |> Plug.Test.conn("/")
    |> Plug.Test.init_test_session(%{})
  end

  describe "generate_and_store_state/1" do
    test "returns a {conn, state} tuple with a non-empty state string" do
      {conn, state} = State.generate_and_store_state(build_conn())

      assert is_binary(state)
      assert byte_size(state) > 0
      assert Plug.Conn.get_session(conn, "_oauth_state") != nil
    end

    test "generates unique states across calls" do
      {_conn1, state1} = State.generate_and_store_state(build_conn())
      {_conn2, state2} = State.generate_and_store_state(build_conn())

      refute state1 == state2
    end
  end

  describe "validate_state/2" do
    test "returns :ok for a valid state with timestamp" do
      {conn, state} = State.generate_and_store_state(build_conn())

      assert :ok = State.validate_state(conn, state)
    end

    test "returns error for mismatched state" do
      {conn, _state} = State.generate_and_store_state(build_conn())

      assert {:error, :invalid_state} = State.validate_state(conn, "wrong-state")
    end

    test "returns error for nil state" do
      conn = build_conn()

      assert {:error, :invalid_state} = State.validate_state(conn, nil)
    end

    test "returns error when no state stored in session" do
      conn = build_conn()

      assert {:error, :invalid_state} = State.validate_state(conn, "some-state")
    end

    test "returns error for expired state" do
      conn = build_conn()

      # Store state with a timestamp 11 minutes in the past
      expired_timestamp = System.system_time(:second) - 660
      state = "test-state"

      conn = Plug.Conn.put_session(conn, "_oauth_state", {state, expired_timestamp})

      assert {:error, :invalid_state} = State.validate_state(conn, state)
    end

    test "accepts state within TTL window" do
      conn = build_conn()

      # Store state with a timestamp 5 minutes in the past (within 10-min TTL)
      recent_timestamp = System.system_time(:second) - 300
      state = "test-state"

      conn = Plug.Conn.put_session(conn, "_oauth_state", {state, recent_timestamp})

      assert :ok = State.validate_state(conn, state)
    end

    test "backward compat: accepts bare string state without timestamp" do
      conn = build_conn()
      state = "legacy-state-value"

      conn = Plug.Conn.put_session(conn, "_oauth_state", state)

      assert :ok = State.validate_state(conn, state)
    end

    test "backward compat: rejects mismatched bare string state" do
      conn = build_conn()

      conn = Plug.Conn.put_session(conn, "_oauth_state", "stored-value")

      assert {:error, :invalid_state} = State.validate_state(conn, "different-value")
    end
  end

  describe "clear_oauth_state/1" do
    test "removes the state from session" do
      {conn, _state} = State.generate_and_store_state(build_conn())

      conn = State.clear_oauth_state(conn)

      assert Plug.Conn.get_session(conn, "_oauth_state") == nil
    end
  end
end
