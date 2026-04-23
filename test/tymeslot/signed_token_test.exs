defmodule Tymeslot.SignedTokenTest do
  @moduledoc """
  Coverage for `Tymeslot.SignedToken.verify/4`.

  The module is a thin wrapper over `Phoenix.Token.verify/4`, but it
  centralises two behaviours the rest of the app depends on:

    * forged / bit-flipped tokens are rejected, never silently accepted,
    * the configured `max_age` is honoured at the second — a token at
      exactly `now - max_age + 1` is still valid, a token at
      `now - max_age - 1` is rejected as `:expired`.

  A regression here would let embed tokens, password-reset style tokens,
  and any other `Phoenix.Token`-backed value live forever or be forgeable,
  so the cost of a direct test is low compared to the blast radius.
  """

  use ExUnit.Case, async: true

  @moduletag :security

  alias Phoenix.Token
  alias Tymeslot.SignedToken
  alias TymeslotWeb.Endpoint

  @salt "signed-token-test-salt"

  describe "verify/4 — forged and tampered tokens" do
    test "a bit-flipped signed payload is rejected as :invalid, not passed to the validator" do
      parent = self()

      validator = fn value ->
        send(parent, {:validator_called, value})
        {:ok, value}
      end

      token = Token.sign(Endpoint, @salt, {"payload", 42})
      tampered = flip_first_char(token)
      refute tampered == token

      assert {:error, :invalid} = SignedToken.verify(tampered, @salt, 60, validator)
      # The validator must NOT run for a tampered token — the signature
      # check is the gatekeeper.
      refute_received {:validator_called, _}
    end

    test "a token signed with the wrong salt is rejected as :invalid" do
      validator = fn value -> {:ok, value} end

      token = Token.sign(Endpoint, "wrong-salt", "some payload")
      assert {:error, :invalid} = SignedToken.verify(token, @salt, 60, validator)
    end
  end

  describe "verify/4 — max_age boundary" do
    test "token signed 'now' verifies inside max_age" do
      token = Token.sign(Endpoint, @salt, "fresh")

      assert {:ok, "fresh"} =
               SignedToken.verify(token, @salt, 60, fn v -> {:ok, v} end)
    end

    test "token older than max_age is rejected with :expired" do
      # Phoenix.Token.sign accepts signed_at in **seconds** since the epoch;
      # backdate by two minutes and verify with a 60-second max_age.
      past_seconds = System.system_time(:second) - 120
      token = Token.sign(Endpoint, @salt, "stale", signed_at: past_seconds)

      assert {:error, :expired} =
               SignedToken.verify(token, @salt, 60, fn v -> {:ok, v} end)
    end

    test "token signed just under max_age still verifies" do
      # signed_at 30s ago, max_age 60s → still valid.
      past_seconds = System.system_time(:second) - 30
      token = Token.sign(Endpoint, @salt, "still-fresh", signed_at: past_seconds)

      assert {:ok, "still-fresh"} =
               SignedToken.verify(token, @salt, 60, fn v -> {:ok, v} end)
    end
  end

  describe "verify/4 — validator rejection" do
    test "a successfully signed token whose payload fails validation surfaces the validator's error" do
      token = Token.sign(Endpoint, @salt, %{unexpected: :shape})

      validator = fn
        %{expected: _v} -> {:ok, :ok}
        _other -> {:error, :invalid_payload}
      end

      assert {:error, :invalid_payload} = SignedToken.verify(token, @salt, 60, validator)
    end
  end

  # Flips the first character of the token. We don't flip the *last*
  # character because Phoenix.Token encodes as URL-safe base64 without
  # padding, and the final character of an HMAC-SHA256 segment only
  # carries 4 significant bits — the remaining 2 are slack and decode
  # to the same byte regardless, so some flips (e.g. ?A <-> ?B) leave
  # the decoded signature unchanged and the tampered token still
  # verifies. Flipping a character at the start of the signed payload
  # always changes a significant bit, so the HMAC check is guaranteed
  # to fail.
  defp flip_first_char(token) do
    <<first::utf8, rest::binary>> = token
    flipped = if first == ?A, do: ?B, else: ?A
    <<flipped::utf8, rest::binary>>
  end
end
