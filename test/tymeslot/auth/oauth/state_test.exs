defmodule Tymeslot.Auth.OAuth.StateTest do
  use ExUnit.Case, async: true
  @moduletag :auth

  alias Plug.Conn
  alias Plug.Test
  alias Tymeslot.Auth.OAuth.State

  defp build_conn do
    :get
    |> Test.conn("/")
    |> Test.init_test_session(%{})
  end

  describe "generate_and_store_state/1" do
    test "returns the state and the S256 challenge of the verifier it stores" do
      {conn, %{state: state, code_challenge: challenge}} =
        State.generate_and_store_state(build_conn())

      # 32 random bytes, url-safe base64 without padding.
      assert state =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert {:ok, verifier} = State.validate_state(conn, state)
      assert verifier =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge
    end

    test "generates unique states across calls" do
      {_conn1, flow1} = State.generate_and_store_state(build_conn())
      {_conn2, flow2} = State.generate_and_store_state(build_conn())

      refute flow1.state == flow2.state
      refute flow1.code_challenge == flow2.code_challenge
    end
  end

  describe "validate_state/2" do
    test "returns the code verifier for a valid state" do
      {conn, %{state: state}} = State.generate_and_store_state(build_conn())

      assert {:ok, _verifier} = State.validate_state(conn, state)
    end

    test "returns error for mismatched state" do
      {conn, _flow} = State.generate_and_store_state(build_conn())

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

    test "rejects a bare string state, which carries no expiry" do
      conn = Conn.put_session(build_conn(), "_oauth_state", "legacy-state-value")

      assert {:error, :invalid_state} = State.validate_state(conn, "legacy-state-value")
    end

    test "rejects a state stored without a code verifier" do
      timestamp = System.system_time(:second)
      conn = Conn.put_session(build_conn(), "_oauth_state", {"pre-pkce", timestamp})

      assert {:error, :invalid_state} = State.validate_state(conn, "pre-pkce")
    end

    test "rejects state at exact TTL boundary (601 seconds)" do
      conn = build_conn()
      state = "boundary-state"
      # 601 seconds ago — just past the 600-second TTL
      timestamp = System.system_time(:second) - 601

      conn = Conn.put_session(conn, "_oauth_state", {state, "verifier", timestamp})

      assert {:error, :invalid_state} = State.validate_state(conn, state)
    end

    test "accepts state just within TTL (599 seconds ago)" do
      conn = build_conn()
      state = "boundary-state"
      # 599 seconds ago — one second of slack to survive a wall-clock tick
      # during validation, which would otherwise push the delta to 601.
      timestamp = System.system_time(:second) - 599

      conn = Conn.put_session(conn, "_oauth_state", {state, "verifier", timestamp})

      assert {:ok, "verifier"} = State.validate_state(conn, state)
    end
  end

  describe "clear_oauth_state/1" do
    test "removes the state from session" do
      {conn, _flow} = State.generate_and_store_state(build_conn())

      conn = State.clear_oauth_state(conn)

      assert Conn.get_session(conn, "_oauth_state") == nil
    end
  end
end
