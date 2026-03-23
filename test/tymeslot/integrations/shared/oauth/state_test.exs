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
      assert {:ok, %{user_id: ^user_id, integration_id: nil}} = State.validate(state, @secret)
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

  describe "generate/3 and validate/2 with integration_id" do
    test "generates and validates a state with integration_id" do
      state = State.generate(123, @secret, 42)
      assert {:ok, %{user_id: 123, integration_id: 42}} = State.validate(state, @secret)
    end

    test "returns nil integration_id when not provided" do
      state = State.generate(123, @secret)
      assert {:ok, %{user_id: 123, integration_id: nil}} = State.validate(state, @secret)
    end

    test "rejects tampered integration_id" do
      state = State.generate(123, @secret, 42)
      [data, _sig] = String.split(state, ".")
      tampered = data <> ".tampered"
      assert {:error, "Invalid state parameter"} = State.validate(tampered, @secret)
    end
  end
end
