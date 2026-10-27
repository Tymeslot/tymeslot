defmodule Tymeslot.Integrations.Calendar.RecurrenceExpanderByRulesTest do
  # Captures the expander's own warning, so it must not share the log with
  # other modules' tests.
  use ExUnit.Case, async: false

  @moduletag :calendar

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  @range_start ~U[2026-01-01 00:00:00Z]
  @half_year_end ~U[2026-06-30 23:59:59Z]

  defp series(rule, first_day) do
    %{
      uid: "series",
      summary: "Series",
      start_time: DateTime.new!(first_day, ~T[09:00:00], "Etc/UTC"),
      end_time: DateTime.new!(first_day, ~T[10:00:00], "Etc/UTC"),
      recurrence_rule: rule
    }
  end

  defp dates(rule, first_day, range_end \\ @half_year_end) do
    rule
    |> series(first_day)
    |> RecurrenceExpander.expand(@range_start, range_end)
    |> Enum.map(&DateTime.to_date(&1.start_time))
  end

  describe "expand/4 with an ordinal BYDAY" do
    test "a second-Tuesday series from Tuesday 13 January occurs every month" do
      assert dates("FREQ=MONTHLY;BYDAY=2TU", ~D[2026-01-13]) == [
               ~D[2026-01-13],
               ~D[2026-02-10],
               ~D[2026-03-10],
               ~D[2026-04-14],
               ~D[2026-05-12],
               ~D[2026-06-09]
             ]
    end

    test "a last-Friday series occurs on the last Friday of every month" do
      assert dates("FREQ=MONTHLY;BYDAY=-1FR", ~D[2026-01-30]) == [
               ~D[2026-01-30],
               ~D[2026-02-27],
               ~D[2026-03-27],
               ~D[2026-04-24],
               ~D[2026-05-29],
               ~D[2026-06-26]
             ]
    end

    test "a yearly fourth-Thursday-of-November series occurs every November" do
      assert dates(
               "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH",
               ~D[2026-11-26],
               ~U[2028-12-31 23:59:59Z]
             ) == [~D[2026-11-26], ~D[2027-11-25], ~D[2028-11-23]]
    end

    test "COUNT counts the occurrences the rule makes, not the months stepped" do
      assert dates("FREQ=MONTHLY;BYDAY=2TU;COUNT=3", ~D[2026-01-13]) ==
               [~D[2026-01-13], ~D[2026-02-10], ~D[2026-03-10]]
    end
  end

  describe "expand/4 with BYMONTHDAY and BYSETPOS" do
    test "BYMONTHDAY=-1 occurs on the last day of every month" do
      assert dates("FREQ=MONTHLY;BYMONTHDAY=-1", ~D[2026-01-31], ~U[2026-04-30 23:59:59Z]) ==
               [~D[2026-01-31], ~D[2026-02-28], ~D[2026-03-31], ~D[2026-04-30]]
    end

    test "BYSETPOS=-1 over the weekdays occurs on the last weekday of every month" do
      assert dates("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", ~D[2026-01-30]) == [
               ~D[2026-01-30],
               ~D[2026-02-27],
               ~D[2026-03-31],
               ~D[2026-04-30],
               ~D[2026-05-29],
               ~D[2026-06-30]
             ]
    end
  end

  describe "expand/4 counting COUNT after BYDAY" do
    # RFC 5545 §3.3.10: "The DTSTART property value always counts as the
    # first occurrence", whether or not the rule would make it.
    test "a weekly series on two days starting on neither occurs first on its start" do
      # Tuesday 13 January is not one of the rule's days; it counts all the same.
      assert dates("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4", ~D[2026-01-13]) ==
               [~D[2026-01-13], ~D[2026-01-14], ~D[2026-01-19], ~D[2026-01-21]]
    end

    test "a monthly series starting off its rule occurs first on its start" do
      # Wednesday 7 January is not the second Tuesday.
      assert dates("FREQ=MONTHLY;BYDAY=2TU;COUNT=3", ~D[2026-01-07]) ==
               [~D[2026-01-07], ~D[2026-01-13], ~D[2026-02-10]]
    end

    test "a start the rule also makes occurs once and counts once" do
      assert dates("FREQ=WEEKLY;BYDAY=TU,TH;COUNT=3", ~D[2026-01-13]) ==
               [~D[2026-01-13], ~D[2026-01-15], ~D[2026-01-20]]
    end

    test "a daily series limited to three weekdays makes COUNT occurrences" do
      assert dates("FREQ=DAILY;BYDAY=MO,WE,FR;COUNT=6", ~D[2026-01-12]) == [
               ~D[2026-01-12],
               ~D[2026-01-14],
               ~D[2026-01-16],
               ~D[2026-01-19],
               ~D[2026-01-21],
               ~D[2026-01-23]
             ]
    end
  end

  describe "count_before/3" do
    test "counts an ordinal BYDAY series as expand/4 steps it" do
      assert RecurrenceExpander.count_before(
               "FREQ=MONTHLY;BYDAY=2TU",
               ~U[2026-01-13 09:00:00Z],
               ~U[2026-06-01 00:00:00Z]
             ) == 5
    end

    test "counts a start the rule does not make" do
      # Tuesday 13 January, then Wednesday 14, Monday 19 and Wednesday 21.
      assert RecurrenceExpander.count_before(
               "FREQ=WEEKLY;BYDAY=MO,WE",
               ~U[2026-01-13 09:00:00Z],
               ~U[2026-01-22 00:00:00Z]
             ) == 4
    end
  end

  describe "expand/4 with a rule part it does not follow" do
    test "logs a warning naming the part" do
      log =
        capture_log(fn ->
          "FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO"
          |> series(~D[2026-05-11])
          |> RecurrenceExpander.expand(@range_start, @half_year_end)
        end)

      assert log =~ "BYWEEKNO"
    end

    test "logs nothing for a rule it follows in full" do
      log =
        capture_log(fn ->
          "FREQ=MONTHLY;BYDAY=2TU;BYMONTH=1,2;BYSETPOS=1;WKST=MO"
          |> series(~D[2026-01-13])
          |> RecurrenceExpander.expand(@range_start, @half_year_end)
        end)

      assert log == ""
    end
  end
end
