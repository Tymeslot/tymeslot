defmodule Tymeslot.Integrations.Common.OAuth.StateTest do
  @moduledoc """
  Tests for OAuth state parameter generation and validation.
  """

  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Common.OAuth.State

  @secret "test-secret-key"

  describe "generate/2 and validate/2" do
    test "generates and validates a state parameter" do
      user_id = 123
      state = State.generate(user_id, @secret)

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

      # Use TTL of 0 seconds so any valid state is immediately expired
      assert {:error, "Invalid or expired state"} = State.validate(state, @secret, 0)
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

  describe "return_to functionality" do
    test "validate/3 on state with return_to includes return_to in result" do
      state = State.generate(123, @secret, nil, return_to: "/dashboard/onboarding")

      assert {:ok, %{user_id: 123, integration_id: nil, return_to: "/dashboard/onboarding"}} =
               State.validate(state, @secret)
    end

    test "validate/3 on state with integration_id and return_to includes both" do
      state = State.generate(123, @secret, 42, return_to: "/dashboard/onboarding")

      assert {:ok, %{user_id: 123, integration_id: 42, return_to: "/dashboard/onboarding"}} =
               State.validate(state, @secret)
    end

    test "validate/3 returns a nil return_to for state without one" do
      state = State.generate(123, @secret)
      assert {:ok, %{return_to: nil}} = State.validate(state, @secret)
    end

    test "generate/4 drops a return_to not starting with /" do
      state = State.generate(123, @secret, nil, return_to: "https://evil.example.com")
      assert {:ok, %{return_to: nil}} = State.validate(state, @secret)
    end

    test "generate/4 drops a return_to starting with //" do
      state = State.generate(123, @secret, nil, return_to: "//evil.example.com")
      assert {:ok, %{return_to: nil}} = State.validate(state, @secret)
    end

    # Browsers treat a backslash as a slash, so `/\evil.example.com` resolves
    # to the protocol-relative `//evil.example.com`.
    test "generate/4 drops a backslash-prefixed return_to" do
      state = State.generate(123, @secret, nil, return_to: "/\\evil.example.com")

      assert {:ok, %{return_to: nil}} = State.validate(state, @secret)
    end

    test "validate/3 rejects a signed backslash-prefixed return_to" do
      # Signed directly, as a state minted before the stricter check would be.
      state = sign("123:#{System.system_time(:second)}|/\\evil.example.com")

      assert {:ok, %{user_id: 123, return_to: nil}} = State.validate(state, @secret)
    end

    test "validate/3 rejects a signed return_to that decodes to a protocol-relative URL" do
      state = sign("123:#{System.system_time(:second)}|/%2F%2Fevil.example.com")

      assert {:ok, %{return_to: nil}} = State.validate(state, @secret)
    end
  end

  defp sign(data) do
    signature = :crypto.mac(:hmac, :sha256, @secret, data)
    "#{Base.url_encode64(data)}.#{Base.url_encode64(signature)}"
  end
end
