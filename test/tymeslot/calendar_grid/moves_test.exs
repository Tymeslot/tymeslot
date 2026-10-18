defmodule Tymeslot.CalendarGrid.MovesTest do
  @moduledoc """
  The timing rules every change of when an event happens follows: wall
  clock to instant across both of London's clock changes, a move keeping
  the event's real length, a resize taking the drawn end, and the span and
  year limits of what the grid can draw.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.Moves

  @london "Europe/London"

  describe "wall_to_utc/2" do
    test "an ordinary summer minute in London is an hour ahead of UTC" do
      assert Moves.wall_to_utc("2026-10-15T11:00", @london) ==
               {:ok, ~U[2026-10-15 10:00:00.000000Z]}
    end

    # 29 March 2026, the last Sunday of March: 01:00 GMT jumps to 02:00 BST.
    test "a minute the spring-forward gap skips becomes the end of the gap" do
      assert Moves.wall_to_utc("2026-03-29T01:30", @london) ==
               {:ok, ~U[2026-03-29 01:00:00Z]}
    end

    # 25 October 2026, the last Sunday of October: 02:00 BST falls back to 01:00 GMT.
    test "a minute the fall-back overlap repeats is its first occurrence" do
      assert Moves.wall_to_utc("2026-10-25T01:30", @london) ==
               {:ok, ~U[2026-10-25 00:30:00.000000Z]}
    end

    test "text that is not a wall-clock minute is refused" do
      assert Moves.wall_to_utc("2026-10-15", @london) == :error
      assert Moves.wall_to_utc("2026-10-15T11:00:30", @london) == :error
      assert Moves.wall_to_utc("tomorrow", @london) == :error
      assert Moves.wall_to_utc(nil, @london) == :error
    end

    test "a zone that does not exist is refused" do
      assert Moves.wall_to_utc("2026-10-15T11:00", "Mars/Olympus_Mons") == :error
    end
  end

  describe "sensible?/2" do
    test "an event that lasts exactly a week can be drawn" do
      assert Moves.sensible?(~U[2026-10-15 09:00:00Z], ~U[2026-10-22 09:00:00Z])
    end

    test "an event a minute longer than a week cannot" do
      refute Moves.sensible?(~U[2026-10-15 09:00:00Z], ~U[2026-10-22 09:01:00Z])
    end

    test "an event that ends when it starts, or before, cannot" do
      refute Moves.sensible?(~U[2026-10-15 09:00:00Z], ~U[2026-10-15 09:00:00Z])
      refute Moves.sensible?(~U[2026-10-15 09:00:00Z], ~U[2026-10-15 08:00:00Z])
    end

    test "the first and last years the grid shows can be drawn in" do
      assert Moves.sensible?(~U[1900-01-01 09:00:00Z], ~U[1900-01-01 10:00:00Z])
      assert Moves.sensible?(~U[2200-12-31 09:00:00Z], ~U[2200-12-31 10:00:00Z])
    end

    test "the years either side of them cannot" do
      refute Moves.sensible?(~U[1899-12-31 09:00:00Z], ~U[1899-12-31 10:00:00Z])
      refute Moves.sensible?(~U[2201-01-01 09:00:00Z], ~U[2201-01-01 10:00:00Z])
    end
  end

  describe "sensible_days?/2" do
    test "one day, and a year and a day, can be drawn" do
      assert Moves.sensible_days?(~D[2026-10-15], ~D[2026-10-16])
      assert Moves.sensible_days?(~D[2026-01-01], ~D[2027-01-02])
    end

    test "a day more than that cannot" do
      refute Moves.sensible_days?(~D[2026-01-01], ~D[2027-01-03])
    end

    test "no days, or fewer, cannot" do
      refute Moves.sensible_days?(~D[2026-10-15], ~D[2026-10-15])
      refute Moves.sensible_days?(~D[2026-10-15], ~D[2026-10-14])
    end

    test "the first and last years can be drawn in, the years either side cannot" do
      assert Moves.sensible_days?(~D[1900-01-01], ~D[1900-01-02])
      assert Moves.sensible_days?(~D[2200-12-30], ~D[2200-12-31])
      refute Moves.sensible_days?(~D[1899-12-30], ~D[1899-12-31])
      refute Moves.sensible_days?(~D[2201-01-01], ~D[2201-01-02])
    end

    test "an end past the last year cannot" do
      refute Moves.sensible_days?(~D[2200-12-31], ~D[2201-01-01])
    end
  end

  describe "resolve/4" do
    test "a move across the October change keeps the hour the event lasts" do
      # 09:00 to 10:00 on Saturday 24 October (BST), drawn on Monday 26 October (GMT).
      event = %{start_at: ~U[2026-10-24 08:00:00Z], end_at: ~U[2026-10-24 09:00:00Z]}

      assert Moves.resolve(event, "2026-10-26T09:00", "2026-10-26T10:00", @london) ==
               {:ok,
                %{
                  start_at: ~U[2026-10-26 09:00:00.000000Z],
                  end_at: ~U[2026-10-26 10:00:00.000000Z]
                }}
    end

    test "an event spanning the October change keeps its real length on an ordinary day" do
      # 00:30 BST to 03:00 GMT on 25 October: three and a half hours, two and
      # a half on the wall. Moved a day later, it still lasts three and a half.
      event = %{start_at: ~U[2026-10-24 23:30:00Z], end_at: ~U[2026-10-25 03:00:00Z]}

      assert Moves.resolve(event, "2026-10-26T00:30", "2026-10-26T03:00", @london) ==
               {:ok,
                %{
                  start_at: ~U[2026-10-26 00:30:00.000000Z],
                  end_at: ~U[2026-10-26 04:00:00.000000Z]
                }}
    end

    test "a move into the March gap starts at the end of the gap and keeps its length" do
      event = %{start_at: ~U[2026-03-28 01:30:00Z], end_at: ~U[2026-03-28 02:30:00Z]}

      assert Moves.resolve(event, "2026-03-29T01:30", "2026-03-29T02:30", @london) ==
               {:ok,
                %{
                  start_at: ~U[2026-03-29 01:00:00Z],
                  end_at: ~U[2026-03-29 02:00:00Z]
                }}
    end

    test "a resize takes the end drawn on the wall" do
      event = %{start_at: ~U[2026-10-15 08:00:00Z], end_at: ~U[2026-10-15 09:00:00Z]}

      assert Moves.resolve(event, "2026-10-15T09:00", "2026-10-15T11:30", @london) ==
               {:ok,
                %{
                  start_at: ~U[2026-10-15 08:00:00.000000Z],
                  end_at: ~U[2026-10-15 10:30:00.000000Z]
                }}
    end

    test "a resize past a week is refused" do
      event = %{start_at: ~U[2026-10-15 08:00:00Z], end_at: ~U[2026-10-15 09:00:00Z]}

      assert Moves.resolve(event, "2026-10-15T09:00", "2026-10-22T09:15", @london) ==
               {:error, :invalid_time}
    end

    test "a resize that ends before it starts is refused" do
      event = %{start_at: ~U[2026-10-15 08:00:00Z], end_at: ~U[2026-10-15 09:00:00Z]}

      assert Moves.resolve(event, "2026-10-15T09:00", "2026-10-15T08:00", @london) ==
               {:error, :invalid_time}
    end

    test "a move to a year the grid cannot show is refused" do
      event = %{start_at: ~U[2026-10-15 08:00:00Z], end_at: ~U[2026-10-15 09:00:00Z]}

      assert Moves.resolve(event, "2201-01-01T09:00", "2201-01-01T10:00", "Etc/UTC") ==
               {:error, :out_of_range}
    end

    test "an unreadable wall clock is refused" do
      event = %{start_at: ~U[2026-10-15 08:00:00Z], end_at: ~U[2026-10-15 09:00:00Z]}

      assert Moves.resolve(event, "2026-10-15T09:00", "later", @london) == {:error, :invalid_time}
      assert Moves.resolve(event, "soon", "2026-10-15T10:00", @london) == {:error, :invalid_time}
    end

    test "an all-day event has no timing to resolve" do
      event = %{start_at: nil, end_at: nil, start_date: ~D[2026-10-15]}

      assert Moves.resolve(event, "2026-10-15T09:00", "2026-10-15T10:00", @london) ==
               {:error, :invalid_time}
    end
  end

  test "Changes.resolve_timing/4 answers what the rules answer" do
    event = %{start_at: ~U[2026-10-24 08:00:00Z], end_at: ~U[2026-10-24 09:00:00Z]}

    assert Changes.resolve_timing(event, "2026-10-26T09:00", "2026-10-26T10:00", @london) ==
             {:ok,
              %{
                start_at: ~U[2026-10-26 09:00:00.000000Z],
                end_at: ~U[2026-10-26 10:00:00.000000Z]
              }}
  end
end
