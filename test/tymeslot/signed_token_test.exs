defmodule Tymeslot.SignedTokenTest do
  @moduledoc """
  Coverage for `Tymeslot.SignedToken`.

  Each purpose keeps the salt its tokens in the wild were signed with, and
  the module centralises the behaviours the rest of the app depends on:

    * forged / bit-flipped tokens are rejected, never silently accepted,
    * each purpose's lifetime is honoured: a token inside it is valid, one
      past it is rejected as `:expired`.

  A regression here would let embed tokens, password-reset style tokens,
  and any other `Phoenix.Token`-backed value live forever or be forgeable,
  so the cost of a direct test is low compared to the blast radius.
  """

  use ExUnit.Case, async: true

  @moduletag :security

  alias Phoenix.Token
  alias Tymeslot.SignedToken
  alias TymeslotWeb.Endpoint

  # The salts tokens in the wild were signed with. A literal per purpose:
  # nothing here is read from the table it checks.
  @salts %{
    embed_session: "embed_session",
    meeting_approval: "meeting approval",
    oauth_signup_confirmation: "oauth typed-email sign-up confirmation",
    booking_preview: "booking owner preview",
    cursor_page: "cursor-page:v1",
    slack_oauth_state: "slack_oauth_state"
  }

  @lifetimes %{
    embed_session: 21_600,
    meeting_approval: 2_419_200,
    oauth_signup_confirmation: 86_400,
    booking_preview: 3600,
    cursor_page: :infinity,
    slack_oauth_state: 600
  }

  describe "purposes" do
    for {purpose, salt} <- @salts do
      test "#{purpose} still accepts a token signed with its old salt" do
        token = Token.sign(Endpoint, unquote(salt), "issued before the table")

        assert SignedToken.verify(unquote(purpose), token) == {:ok, "issued before the table"}
      end
    end

    test "each purpose keeps its lifetime" do
      for {purpose, max_age} <- @lifetimes, do: assert(SignedToken.max_age(purpose) == max_age)
    end

    test "a token signed for one purpose does not verify as another" do
      token = SignedToken.sign(:booking_preview, 42)

      assert SignedToken.verify(:booking_preview, token) == {:ok, 42}
      assert SignedToken.verify(:meeting_approval, token) == {:error, :invalid}
    end
  end

  describe "verify/3: forged and tampered tokens" do
    test "a bit-flipped signed payload is rejected as :invalid, not passed to the validator" do
      parent = self()

      validator = fn value ->
        send(parent, {:validator_called, value})
        {:ok, value}
      end

      token = SignedToken.sign(:booking_preview, {"payload", 42})
      tampered = flip_first_char(token)
      refute tampered == token

      assert {:error, :invalid} =
               SignedToken.verify(:booking_preview, tampered, validate: validator)

      # The validator must NOT run for a tampered token: the signature check
      # is the gatekeeper.
      refute_received {:validator_called, _}
    end
  end

  describe "verify/3: lifetime" do
    test "a token older than its purpose's lifetime is rejected with :expired" do
      two_hours_ago = System.system_time(:second) - 7200
      token = Token.sign(Endpoint, "booking owner preview", "stale", signed_at: two_hours_ago)

      assert SignedToken.verify(:booking_preview, token) == {:error, :expired}
    end

    test "a token just inside its lifetime still verifies" do
      half_an_hour_ago = System.system_time(:second) - 1800
      token = Token.sign(Endpoint, "booking owner preview", "fresh", signed_at: half_an_hour_ago)

      assert SignedToken.verify(:booking_preview, token) == {:ok, "fresh"}
    end

    test ":max_age overrides the purpose's lifetime" do
      two_minutes_ago = System.system_time(:second) - 120
      token = Token.sign(Endpoint, "embed_session", "short", signed_at: two_minutes_ago)

      assert SignedToken.verify(:embed_session, token, max_age: 60) == {:error, :expired}
      assert SignedToken.verify(:embed_session, token) == {:ok, "short"}
    end
  end

  describe "verify/3: validator rejection" do
    test "a validly signed token whose payload fails validation surfaces the validator's error" do
      token = SignedToken.sign(:booking_preview, %{unexpected: :shape})

      validator = fn
        %{expected: _v} -> {:ok, :ok}
        _other -> {:error, :invalid_payload}
      end

      assert SignedToken.verify(:booking_preview, token, validate: validator) ==
               {:error, :invalid_payload}
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
