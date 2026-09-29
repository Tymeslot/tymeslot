defmodule Tymeslot.Integrations.Calendar.Recurrence.SplitExceptionsTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Calendar.Recurrence.SplitExceptions

  # A weekly series at 09:00 for an hour, split at 2 November.
  @timing {~N[2026-06-01 09:00:00], ~N[2026-06-01 10:00:00]}
  @slot ~N[2026-11-02 09:00:00]

  defp edited(day, fields, {from, until}) do
    %{
      slot: NaiveDateTime.new!(day, ~T[09:00:00]),
      change: {:edited, fields, {NaiveDateTime.new!(day, from), NaiveDateTime.new!(day, until)}}
    }
  end

  describe "plan/4" do
    test "leaves the occurrences before the slot, and those with nothing of their own, to the head" do
      exceptions = [
        edited(~D[2026-10-26], %{"summary" => "Old"}, {~T[09:00:00], ~T[10:00:00]}),
        edited(~D[2026-11-09], %{}, {~T[09:00:00], ~T[10:00:00]}),
        %{slot: ~N[2026-11-16 09:00:00], change: :cancelled}
      ]

      assert SplitExceptions.plan(exceptions, @slot, @timing, :unmoved) == [
               %{target: ~N[2026-11-16 09:00:00], change: :cancelled}
             ]
    end

    test "an unmoved occurrence carries its fields alone, a moved one its timing too" do
      exceptions = [
        edited(~D[2026-11-09], %{"summary" => "Retro"}, {~T[09:00:00], ~T[10:00:00]}),
        edited(~D[2026-11-16], %{}, {~T[14:00:00], ~T[15:00:00]})
      ]

      assert SplitExceptions.plan(exceptions, @slot, @timing, :unmoved) == [
               %{
                 target: ~N[2026-11-09 09:00:00],
                 change: {:edited, %{"summary" => "Retro"}, nil}
               },
               %{
                 target: ~N[2026-11-16 09:00:00],
                 change: {:edited, %{}, {~N[2026-11-16 14:00:00], ~N[2026-11-16 15:00:00]}}
               }
             ]
    end

    # The edit moves the series an hour later and makes it last two.
    @move %{start: ~N[2026-06-01 10:00:00], end: ~N[2026-06-01 12:00:00], shift: 3600, days: 0}

    test "a move takes each target and timing with it; the series' new length goes to those that had its old one" do
      exceptions = [
        edited(~D[2026-11-09], %{}, {~T[14:00:00], ~T[15:00:00]}),
        edited(~D[2026-11-16], %{}, {~T[14:00:00], ~T[14:30:00]})
      ]

      assert SplitExceptions.plan(exceptions, @slot, @timing, @move) == [
               %{
                 target: ~N[2026-11-09 10:00:00],
                 change: {:edited, %{}, {~N[2026-11-09 15:00:00], ~N[2026-11-09 17:00:00]}}
               },
               %{
                 target: ~N[2026-11-16 10:00:00],
                 change: {:edited, %{}, {~N[2026-11-16 15:00:00], ~N[2026-11-16 15:30:00]}}
               }
             ]
    end

    test "an all-day series moves by whole days" do
      exceptions = [%{slot: ~D[2026-11-09], change: :cancelled}]
      move = %{start: ~D[2026-06-02], end: ~D[2026-06-03], shift: 86_400, days: 1}

      assert SplitExceptions.plan(
               exceptions,
               ~D[2026-11-02],
               {~D[2026-06-01], ~D[2026-06-02]},
               move
             ) ==
               [%{target: ~D[2026-11-10], change: :cancelled}]
    end
  end

  describe "carry/2" do
    test "counts each outcome, and a write that raises fails only itself" do
      carries = for day <- 1..4, do: %{target: Date.new!(2026, 11, day), change: :cancelled}

      write = fn
        %{target: ~D[2026-11-01]} -> :ok
        %{target: ~D[2026-11-02]} -> :unmatched
        %{target: ~D[2026-11-03]} -> {:error, :rate_limited}
        %{target: ~D[2026-11-04]} -> raise "boom"
      end

      log =
        capture_log(fn ->
          assert SplitExceptions.carry(carries, write) == %{carried: 1, unmatched: 1, failed: 2}
        end)

      assert log =~ "Could not carry every occurrence changed on its own"
    end
  end
end
