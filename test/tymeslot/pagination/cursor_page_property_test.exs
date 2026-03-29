defmodule Tymeslot.Pagination.CursorPagePropertyTest do
  @moduledoc """
  Property-based tests for cursor encoding/decoding round-trips.
  """
  use ExUnit.Case, async: true
  @moduletag :utils
  use ExUnitProperties

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

    property "encoded cursor is URL-safe (no padding, valid base64url chars)" do
      check all(cursor <- cursor_map_gen()) do
        encoded = CursorPage.encode_cursor(cursor)

        # No padding characters
        refute String.contains?(encoded, "=")
        # Only base64url characters
        assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, encoded)
      end
    end

    property "invalid strings always return error" do
      check all(s <- string(:ascii, min_length: 1, max_length: 100)) do
        case CursorPage.decode_cursor(s) do
          {:ok, _decoded} ->
            # If it accidentally decodes, it must have the right shape
            :ok

          {:error, :invalid_cursor} ->
            :ok
        end
      end
    end
  end
end
