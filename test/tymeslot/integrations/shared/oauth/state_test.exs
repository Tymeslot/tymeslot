defmodule Tymeslot.Integrations.Common.OAuth.StateTest do
  @moduledoc """
  Tests for OAuth state parameter generation and validation.

  ## Note on Process.sleep Usage

  This file uses `Process.sleep/1` to test time-based expiration of OAuth state
  tokens. The sleep is necessary to verify that tokens correctly expire after
  their TTL, testing security-critical timeout behavior.
  """

  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Common.OAuth.State

  @secret "test-secret-key"

  describe "generate/2 and validate/2" do
    test "generates and validates a state parameter" do
      user_id = 123
      state = State.generate(user_id, @secret)

      assert is_binary(state)
      assert {:ok, ^user_id} = State.validate(state, @secret)
    end

    test "fails with invalid secret" do
      state = State.generate(123, @secret)
      assert {:error, "Invalid state parameter"} = State.validate(state, "wrong-secret")
    end

    test "fails with tampered state" do
      state = State.generate(123, @secret)
      [data, signature] = String.split(state, ".")

      # Tamper with data
      tampered_state = "tampered." <> signature
      assert {:error, "Invalid state parameter"} = State.validate(tampered_state, @secret)

      # Tamper with signature
      tampered_state2 = data <> ".tampered"
      assert {:error, "Invalid state parameter"} = State.validate(tampered_state2, @secret)
    end

    test "fails when expired" do
      # We can't easily travel in time with System.system_time,
      # but we can pass a very small TTL
      state = State.generate(123, @secret)

      # Sleep for 2 seconds and use 1 second TTL
      Process.sleep(1100)
      assert {:error, "Invalid or expired state"} = State.validate(state, @secret, 1)
    end

    test "fails with invalid format" do
      assert {:error, "Invalid state parameter"} = State.validate("not-a-state", @secret)
      assert {:error, "Invalid state parameter"} = State.validate(nil, @secret)
    end
  end
end
