defmodule TymeslotWeb.Dashboard.AgendaTimelineTest do
  @moduledoc """
  Unit tests for the agenda day-spine builder: now-line placement, gap
  compression, in-progress handling, and the hero marker. All reasoning is on
  time *diffs* against a fixed `now`, so these are deterministic.
  """
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :dashboard

  alias Tymeslot.Agenda.Entry
  alias TymeslotWeb.Dashboard.AgendaTimeline

  @now ~U[2026-07-02 09:00:00Z]

  describe "spine/3 now-line and gaps" do
    test "returns no rows for an empty day, so no lone now-line is rendered" do
      assert AgendaTimeline.spine([], @now) == []
    end

    test "leads with the now-line and a labelled runway to the first entry" do
      entry = entry("a", ~U[2026-07-02 10:00:00Z], ~U[2026-07-02 11:00:00Z])

      assert [:now, {:gap, 60}, {:event, ^entry, [next?: false, in_progress?: false]}] =
               AgendaTimeline.spine([entry], @now)
    end

    test "omits a runway shorter than the 30-minute threshold" do
      entry = entry("a", ~U[2026-07-02 09:20:00Z], ~U[2026-07-02 10:00:00Z])

      assert [:now, {:event, ^entry, _meta}] = AgendaTimeline.spine([entry], @now)
    end

    test "labels the free stretch between two spaced entries" do
      earlier = entry("a", ~U[2026-07-02 10:00:00Z], ~U[2026-07-02 10:30:00Z])
      later = entry("b", ~U[2026-07-02 12:00:00Z], ~U[2026-07-02 13:00:00Z])

      assert [
               :now,
               {:gap, 60},
               {:event, ^earlier, _m1},
               {:gap, 90},
               {:event, ^later, _m2}
             ] = AgendaTimeline.spine([earlier, later], @now)
    end

    test "draws no gap between back-to-back entries" do
      earlier = entry("a", ~U[2026-07-02 10:00:00Z], ~U[2026-07-02 11:00:00Z])
      later = entry("b", ~U[2026-07-02 11:00:00Z], ~U[2026-07-02 12:00:00Z])

      assert [:now, {:gap, 60}, {:event, ^earlier, _m1}, {:event, ^later, _m2}] =
               AgendaTimeline.spine([earlier, later], @now)
    end

    test "sorts entries before assembling the spine" do
      later = entry("b", ~U[2026-07-02 12:00:00Z], ~U[2026-07-02 13:00:00Z])
      earlier = entry("a", ~U[2026-07-02 10:00:00Z], ~U[2026-07-02 10:30:00Z])

      assert [
               :now,
               {:gap, 60},
               {:event, ^earlier, _m1},
               {:gap, 90},
               {:event, ^later, _m2}
             ] =
               AgendaTimeline.spine([later, earlier], @now)
    end
  end

  describe "spine/3 in-progress handling" do
    test "places an in-progress entry before the now-line and suppresses the runway" do
      running = entry("live", ~U[2026-07-02 08:30:00Z], ~U[2026-07-02 09:30:00Z])
      upcoming = entry("next", ~U[2026-07-02 11:00:00Z], ~U[2026-07-02 12:00:00Z])

      assert [
               {:event, ^running, [next?: false, in_progress?: true]},
               :now,
               {:event, ^upcoming, [next?: false, in_progress?: false]}
             ] = AgendaTimeline.spine([running, upcoming], @now)
    end
  end

  describe "spine/3 hero marking" do
    test "flags the entry whose id matches next_id" do
      first = entry("a", ~U[2026-07-02 10:00:00Z], ~U[2026-07-02 10:30:00Z])
      second = entry("b", ~U[2026-07-02 12:00:00Z], ~U[2026-07-02 13:00:00Z])

      spine = AgendaTimeline.spine([first, second], @now, "b")

      assert {:event, ^second, [next?: true, in_progress?: false]} = List.last(spine)
      assert Enum.any?(spine, &match?({:event, ^first, [next?: false, in_progress?: false]}, &1))
    end
  end

  describe "format_gap/1" do
    test "formats sub-hour, whole-hour, and mixed durations" do
      assert AgendaTimeline.format_gap(45) == "45m free"
      assert AgendaTimeline.format_gap(60) == "1h free"
      assert AgendaTimeline.format_gap(135) == "2h 15m free"
    end
  end

  defp entry(id, start_at, end_at) do
    %Entry{
      id: id,
      source: :tymeslot,
      title: id,
      day: DateTime.to_date(start_at),
      start_at: start_at,
      end_at: end_at,
      all_day?: false,
      location: nil,
      join_url: nil,
      who: nil
    }
  end
end
