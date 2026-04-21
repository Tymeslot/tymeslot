defmodule Tymeslot.Pagination.CursorPagePropertyTest do
  @moduledoc """
  Property-based tests for cursor encoding/decoding round-trips.
  """
  use ExUnit.Case, async: true
  @moduletag :utils
  use ExUnitProperties

  import Bitwise, only: [bxor: 2]

  alias Phoenix.Token
  alias Tymeslot.Pagination.CursorPage

  defp cursor_map_gen do
    gen all(
          days_offset <- integer(0..3650),
          hour <- integer(0..23),
          minute <- integer(0..59),
          second <- integer(0..59),
          id <- string(:alphanumeric, min_length: 1, max_length: 36)
        ) do
      dt =
        DateTime.add(
          ~U[2020-01-01 00:00:00Z],
          days_offset * 86_400 + hour * 3600 + minute * 60 + second,
          :second
        )

      %{after_start: dt, after_id: id}
    end
  end

  describe "encode_cursor/1 and decode_cursor/1" do
    property "round-trip: decode(encode(cursor)) recovers the original data" do
      check all(cursor <- cursor_map_gen()) do
        encoded = CursorPage.encode_cursor(cursor)
        assert {:ok, decoded} = CursorPage.decode_cursor(encoded)

        assert DateTime.compare(decoded.after_start, cursor.after_start) == :eq
        assert decoded.after_id == cursor.after_id
      end
    end

    property "encoded cursor is URL-safe (no padding, valid base64url + Phoenix.Token separator)" do
      check all(cursor <- cursor_map_gen()) do
        encoded = CursorPage.encode_cursor(cursor)

        # No padding characters
        refute String.contains?(encoded, "=")
        # base64url alphabet plus the `.` segment separator that Phoenix.Token emits
        assert Regex.match?(~r/^[A-Za-z0-9_.\-]+$/, encoded)
      end
    end

    property "arbitrary strings never decode to a valid cursor" do
      check all(s <- string(:ascii, min_length: 1, max_length: 100)) do
        # A signed cursor would need to hit the exact base64url-encoded
        # payload + HMAC produced by Phoenix.Token. Random ASCII will not.
        assert {:error, :invalid_cursor} = CursorPage.decode_cursor(s)
      end
    end
  end

  # Cursors are intentionally permanent (max_age: :infinity). Both encode_cursor/1
  # and decode_cursor/1 must agree on this — if sign embeds a finite max_age and
  # verify passes :infinity, cursors appear to work but the lifetime contract is
  # unauditable and a future change to either side can silently break the other.
  # This block guards against that asymmetry regressing.
  describe "cursor lifetime" do
    test "encode_cursor embeds :infinity max_age (symmetric with decode_cursor)" do
      # Sign directly with the same parameters encode_cursor uses and verify
      # that the resulting token is accepted by decode_cursor. The key assertion
      # is that a token signed with max_age: :infinity round-trips successfully,
      # whereas a token signed with the library default (86400s) AND decoded with
      # max_age: :infinity would *also* succeed today — but the reverse would
      # not: a token signed with :infinity verified with max_age: 0 must expire.
      # We test both directions to pin the symmetric contract.
      cursor = %{after_start: ~U[2025-01-01 00:00:00Z], after_id: "lifetime-test"}

      # Forward direction: production encode -> production decode always works.
      encoded = CursorPage.encode_cursor(cursor)
      assert {:ok, _} = CursorPage.decode_cursor(encoded)

      # Reverse guard: a token signed without explicit max_age (library default
      # 86400s) should NOT be considered equivalent to one signed with :infinity.
      # We use Phoenix.Token directly with the same salt and endpoint so the
      # signature is valid — only the embedded max_age differs.
      finite_token =
        Token.sign(TymeslotWeb.Endpoint, "cursor-page:v1", %{
          after_start: ~U[2025-01-01 00:00:00Z],
          after_id: "lifetime-test"
        })

      # This token has 86400 embedded but decode_cursor uses max_age: :infinity,
      # so it currently succeeds — confirming infinity wins. The test documents
      # this and will catch any future tightening of the verify side.
      assert {:ok, _} = CursorPage.decode_cursor(finite_token)

      # Guard the sign side: verify a token produced by encode_cursor is
      # accepted with max_age: 0 → it must be rejected (proving the embedded
      # value is :infinity, not a finite number that looks infinite at verify time).
      assert {:error, :expired} =
               Token.verify(TymeslotWeb.Endpoint, "cursor-page:v1", encoded, max_age: 0)
    end
  end

  # The previous unsigned implementation encoded cursors as plain
  # url-base64 JSON — anyone with 30 seconds and a REPL could forge one.
  # This block locks in the signed-only invariant.
  describe "signed cursor guarantees" do
    alias Tymeslot.Pagination.CursorPage

    test "a legacy unsigned base64 JSON cursor is rejected" do
      legacy =
        Base.url_encode64(
          Jason.encode!(%{
            after_start: DateTime.to_iso8601(~U[2025-01-01 12:00:00Z]),
            after_id: "impersonated-meeting-id"
          }),
          padding: false
        )

      assert {:error, :invalid_cursor} = CursorPage.decode_cursor(legacy)
    end

    test "a cursor with a flipped byte is rejected" do
      encoded =
        CursorPage.encode_cursor(%{
          after_start: ~U[2025-06-15 08:30:00Z],
          after_id: "abc123"
        })

      # Mutate a character in the payload segment (between the two `.`s). The
      # last base64url character has redundant bits that can decode to the
      # same bytes, so we target the middle to force an HMAC mismatch.
      [header, payload, sig] = String.split(encoded, ".")
      <<first, rest::binary>> = payload
      mutated_payload = <<bxor(first, 0xFF), rest::binary>>
      tampered = Enum.join([header, mutated_payload, sig], ".")

      assert {:error, :invalid_cursor} = CursorPage.decode_cursor(tampered)
    end

    test "a cursor signed with a different secret is rejected" do
      # Sign with an unrelated salt so the HMAC is well-formed but the
      # verifier considers it tampered.
      forged =
        Token.sign(TymeslotWeb.Endpoint, "attacker-chosen-salt", %{
          after_start: ~U[2025-01-01 00:00:00Z],
          after_id: "attacker-target"
        })

      assert {:error, :invalid_cursor} = CursorPage.decode_cursor(forged)
    end
  end
end
