defmodule Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverterTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  @start_date ~D[2026-06-15]

  describe "rrule_to_outlook/2 — pattern" do
    test "daily pattern" do
      %{"pattern" => pattern} = to_outlook("FREQ=DAILY", @start_date)
      assert pattern["type"] == "daily"
      assert pattern["interval"] == 1
    end

    test "daily pattern carries interval" do
      %{"pattern" => pattern} =
        to_outlook("FREQ=DAILY;INTERVAL=3", @start_date)

      assert pattern["interval"] == 3
    end

    test "weekly pattern with daysOfWeek" do
      %{"pattern" => pattern} =
        to_outlook("FREQ=WEEKLY;BYDAY=MO,WE", @start_date)

      assert pattern["type"] == "weekly"
      assert pattern["daysOfWeek"] == ["monday", "wednesday"]
    end

    test "weekly pattern without BYDAY falls back to the start date's weekday" do
      # 2026-06-15 is a Monday
      %{"pattern" => pattern} =
        to_outlook("FREQ=WEEKLY", @start_date)

      assert pattern["type"] == "weekly"
      assert pattern["daysOfWeek"] == ["monday"]
    end

    test "monthly pattern is absoluteMonthly anchored on the start day" do
      %{"pattern" => pattern} =
        to_outlook("FREQ=MONTHLY", @start_date)

      assert pattern["type"] == "absoluteMonthly"
      assert pattern["dayOfMonth"] == 15
    end

    test "yearly pattern is absoluteYearly anchored on the start month and day" do
      %{"pattern" => pattern} =
        to_outlook("FREQ=YEARLY", @start_date)

      assert pattern["type"] == "absoluteYearly"
      assert pattern["dayOfMonth"] == 15
      assert pattern["month"] == 6
    end
  end

  describe "rrule_to_outlook/2 — a day some months lack" do
    # Graph would move these onto 28 February, 30 April and so on, where
    # RFC 5545 skips the month.
    for {rrule, start_date} <- [
          {"FREQ=MONTHLY", ~D[2026-01-29]},
          {"FREQ=MONTHLY", ~D[2026-01-30]},
          {"FREQ=MONTHLY", ~D[2026-01-31]},
          {"FREQ=MONTHLY;INTERVAL=2", ~D[2026-03-31]},
          {"FREQ=YEARLY", ~D[2028-02-29]},
          {"FREQ=YEARLY;INTERVAL=4", ~D[2028-02-29]}
        ] do
      test "refuses #{rrule} from #{start_date}" do
        assert RecurrenceConverter.rrule_to_outlook(
                 unquote(rrule),
                 unquote(Macro.escape(start_date))
               ) ==
                 {:error, :day_missing_in_some_months}
      end
    end

    # Each ends, or steps, before a period without the day.
    for {rrule, start_date} <- [
          {"FREQ=MONTHLY", ~D[2026-01-28]},
          {"FREQ=MONTHLY;COUNT=1", ~D[2026-01-31]},
          {"FREQ=MONTHLY;COUNT=2", ~D[2026-07-31]},
          {"FREQ=MONTHLY;UNTIL=20260829", ~D[2026-07-31]},
          {"FREQ=MONTHLY;INTERVAL=6", ~D[2026-01-31]},
          {"FREQ=MONTHLY;INTERVAL=12", ~D[2026-03-31]},
          {"FREQ=YEARLY", ~D[2026-01-31]},
          {"FREQ=YEARLY;COUNT=1", ~D[2028-02-29]}
        ] do
      test "writes #{rrule} from #{start_date} on its own day" do
        assert {:ok, %{"pattern" => %{"dayOfMonth" => day}}} =
                 RecurrenceConverter.rrule_to_outlook(
                   unquote(rrule),
                   unquote(Macro.escape(start_date))
                 )

        assert day == unquote(start_date.day)
      end
    end

    # The day named by BYMONTHDAY or BYMONTH, not the start's, is the one a
    # month may lack.
    for {rrule, start_date} <- [
          {"FREQ=MONTHLY;BYMONTHDAY=31", ~D[2026-01-15]},
          {"FREQ=YEARLY;BYMONTH=4", ~D[2026-01-31]},
          {"FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29", ~D[2028-01-10]}
        ] do
      test "refuses #{rrule} from #{start_date}" do
        assert RecurrenceConverter.rrule_to_outlook(
                 unquote(rrule),
                 unquote(Macro.escape(start_date))
               ) ==
                 {:error, :day_missing_in_some_months}
      end
    end

    test "writes a 29 February BYMONTHDAY series that ends in its leap year" do
      assert {:ok, %{"pattern" => %{"dayOfMonth" => 29, "month" => 2}}} =
               RecurrenceConverter.rrule_to_outlook(
                 "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29;COUNT=1",
                 ~D[2028-01-10]
               )
    end

    test "writes a BYMONTHDAY series on a day every month has" do
      assert {:ok, %{"pattern" => %{"dayOfMonth" => 28}}} =
               RecurrenceConverter.rrule_to_outlook("FREQ=MONTHLY;BYMONTHDAY=28", ~D[2026-01-31])
    end

    test "refuses a series whose UNTIL reaches the last day of a short month" do
      assert RecurrenceConverter.rrule_to_outlook("FREQ=MONTHLY;UNTIL=20260930", ~D[2026-08-31]) ==
               {:error, :day_missing_in_some_months}
    end
  end

  describe "rrule_to_outlook/2 — range" do
    test "noEnd range when neither COUNT nor UNTIL present" do
      %{"range" => range} = to_outlook("FREQ=DAILY", @start_date)
      assert range["type"] == "noEnd"
      assert range["startDate"] == "2026-06-15"
    end

    test "numbered range from COUNT" do
      %{"range" => range} =
        to_outlook("FREQ=DAILY;COUNT=10", @start_date)

      assert range["type"] == "numbered"
      assert range["numberOfOccurrences"] == 10
    end

    test "endDate range from UNTIL" do
      %{"range" => range} =
        to_outlook("FREQ=WEEKLY;UNTIL=20261231T235959Z", @start_date)

      assert range["type"] == "endDate"
      assert range["endDate"] == "2026-12-31"
    end
  end

  describe "outlook_to_rrule/1" do
    test "converts a daily pattern" do
      recurrence = %{
        "pattern" => %{"type" => "daily", "interval" => 2},
        "range" => %{"type" => "noEnd"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) == "FREQ=DAILY;INTERVAL=2"
    end

    test "converts a weekly pattern with daysOfWeek" do
      recurrence = %{
        "pattern" => %{
          "type" => "weekly",
          "interval" => 1,
          "daysOfWeek" => ["monday", "wednesday", "friday"]
        },
        "range" => %{"type" => "noEnd"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) ==
               "FREQ=WEEKLY;BYDAY=MO,WE,FR;WKST=SU"
    end

    test "converts absoluteMonthly to MONTHLY" do
      recurrence = %{
        "pattern" => %{"type" => "absoluteMonthly", "interval" => 1, "dayOfMonth" => 15},
        "range" => %{"type" => "noEnd"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) == "FREQ=MONTHLY"
    end

    test "converts absoluteYearly to YEARLY" do
      recurrence = %{
        "pattern" => %{"type" => "absoluteYearly", "interval" => 1},
        "range" => %{"type" => "noEnd"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) == "FREQ=YEARLY"
    end

    test "converts a numbered range to COUNT" do
      recurrence = %{
        "pattern" => %{"type" => "daily", "interval" => 1},
        "range" => %{"type" => "numbered", "numberOfOccurrences" => 5}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) == "FREQ=DAILY;COUNT=5"
    end

    test "converts an endDate range to UNTIL" do
      recurrence = %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["tuesday"]},
        "range" => %{"type" => "endDate", "endDate" => "2026-12-31"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) ==
               "FREQ=WEEKLY;BYDAY=TU;WKST=SU;UNTIL=20261231T235959Z"
    end

    test "returns nil for an unrecognised map" do
      assert RecurrenceConverter.outlook_to_rrule(%{}) == nil
      assert RecurrenceConverter.outlook_to_rrule(nil) == nil
    end
  end

  describe "round-trip rrule -> outlook -> rrule" do
    for rrule <- [
          "FREQ=DAILY;INTERVAL=3",
          "FREQ=WEEKLY;BYDAY=MO,WE,FR",
          "FREQ=DAILY;COUNT=10",
          "FREQ=WEEKLY;BYDAY=TU;UNTIL=20261231T235959Z"
        ] do
      test "round-trips #{rrule}" do
        rrule = unquote(rrule)
        outlook = to_outlook(rrule, ~D[2026-06-16])
        assert RecurrenceConverter.outlook_to_rrule(outlook) == rrule
      end
    end
  end

  # Which days of an every-other-week series share a week depends on the day
  # the week starts on: Monday for an RRULE without WKST, Sunday for a Graph
  # pattern without firstDayOfWeek.
  describe "week start" do
    for {rrule, first_day} <- [
          {"FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO", "monday"},
          {"FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=SU", "sunday"}
        ] do
      test "writes #{rrule} starting its weeks on #{first_day}, and reads it back" do
        rrule = unquote(rrule)
        outlook = to_outlook(rrule, @start_date)

        assert outlook["pattern"]["firstDayOfWeek"] == unquote(first_day)
        assert RecurrenceConverter.outlook_to_rrule(outlook) == rrule
      end
    end

    # 15 June 2026 is a Monday. In weeks starting on Sunday its fortnight
    # resumes on Sunday 28 June; in weeks starting on Monday, the Sunday
    # after it belongs to its own week.
    test "reads a pattern back so that its Sundays fall in the weeks Graph puts them in" do
      assert expand_read_back("sunday") ==
               [~D[2026-06-15], ~D[2026-06-28], ~D[2026-06-29], ~D[2026-07-12], ~D[2026-07-13]]

      assert expand_read_back("monday") ==
               [~D[2026-06-15], ~D[2026-06-21], ~D[2026-06-29], ~D[2026-07-05], ~D[2026-07-13]]
    end

    test "reads a weekly pattern stating no week start as starting on Sunday" do
      recurrence = %{
        "pattern" => %{"type" => "weekly", "interval" => 2, "daysOfWeek" => ["monday"]},
        "range" => %{"type" => "noEnd", "startDate" => "2026-06-15"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) ==
               "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;WKST=SU"
    end

    test "leaves it off every pattern but a weekly one" do
      refute Map.has_key?(
               to_outlook("FREQ=MONTHLY;BYDAY=2TU;WKST=SU", @start_date)["pattern"],
               "firstDayOfWeek"
             )

      recurrence = %{
        "pattern" => %{
          "type" => "relativeMonthly",
          "interval" => 1,
          "daysOfWeek" => ["tuesday"],
          "index" => "second",
          "firstDayOfWeek" => "sunday"
        },
        "range" => %{"type" => "noEnd", "startDate" => "2026-06-09"}
      }

      assert RecurrenceConverter.outlook_to_rrule(recurrence) == "FREQ=MONTHLY;BYDAY=2TU"
    end
  end

  describe "patterns counted within the month" do
    # 2026-06-09 is the second Tuesday of June.
    @second_tuesday ~D[2026-06-09]

    test "one counted weekday is a relative monthly pattern, not the start's day of the month" do
      assert {:ok, %{"pattern" => pattern}} =
               RecurrenceConverter.rrule_to_outlook("FREQ=MONTHLY;BYDAY=2TU", @second_tuesday)

      assert pattern == %{
               "type" => "relativeMonthly",
               "daysOfWeek" => ["tuesday"],
               "index" => "second",
               "interval" => 1
             }
    end

    test "the last weekday of the month is counted from its end" do
      %{"pattern" => pattern} = to_outlook("FREQ=MONTHLY;BYDAY=-1FR", ~D[2026-06-26])

      assert %{"type" => "relativeMonthly", "daysOfWeek" => ["friday"], "index" => "last"} =
               pattern
    end

    test "a set of weekdays with one position picks among them" do
      %{"pattern" => pattern} =
        to_outlook("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", ~D[2026-06-30])

      assert pattern["type"] == "relativeMonthly"
      assert pattern["daysOfWeek"] == ~w(monday tuesday wednesday thursday friday)
      assert pattern["index"] == "last"
    end

    test "a yearly counted weekday is a relative yearly pattern in its month" do
      # Thanksgiving: the fourth Thursday of November.
      %{"pattern" => pattern} =
        to_outlook("FREQ=YEARLY;BYMONTH=11;BYDAY=4TH", ~D[2026-11-26])

      assert pattern == %{
               "type" => "relativeYearly",
               "daysOfWeek" => ["thursday"],
               "index" => "fourth",
               "month" => 11,
               "interval" => 1
             }
    end

    test "one stated day of the month is that day, whatever the start" do
      %{"pattern" => pattern} = to_outlook("FREQ=MONTHLY;BYMONTHDAY=20", @start_date)

      assert pattern["type"] == "absoluteMonthly"
      assert pattern["dayOfMonth"] == 20
    end

    test "a daily rule on some weekdays is a weekly pattern on those days" do
      %{"pattern" => pattern} = to_outlook("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR", @start_date)

      assert pattern["type"] == "weekly"
      assert pattern["daysOfWeek"] == ~w(monday tuesday wednesday thursday friday)
      assert pattern["interval"] == 1
    end

    for rrule <- [
          "FREQ=MONTHLY;BYDAY=2TU",
          "FREQ=MONTHLY;BYDAY=-1FR;COUNT=6",
          "FREQ=MONTHLY;INTERVAL=2;BYDAY=1MO",
          "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1",
          "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH"
        ] do
      test "round-trips #{rrule}" do
        assert unquote(rrule) ==
                 unquote(rrule)
                 |> to_outlook(@second_tuesday)
                 |> RecurrenceConverter.outlook_to_rrule()
      end
    end
  end

  describe "rules Outlook has no pattern for" do
    for rrule <- [
          "FREQ=MONTHLY;BYDAY=2TU,4TU",
          "FREQ=MONTHLY;BYDAY=5MO",
          "FREQ=MONTHLY;BYDAY=-2FR",
          "FREQ=MONTHLY;BYDAY=TU",
          "FREQ=MONTHLY;BYDAY=MO,FR;BYSETPOS=-2",
          "FREQ=MONTHLY;BYDAY=MO,FR;BYSETPOS=1,2",
          "FREQ=MONTHLY;BYMONTHDAY=1,15",
          "FREQ=MONTHLY;BYMONTHDAY=-1",
          "FREQ=MONTHLY;BYMONTH=3",
          "FREQ=YEARLY;BYMONTH=1,7",
          "FREQ=YEARLY;BYDAY=2TU",
          "FREQ=YEARLY;BYMONTHDAY=1",
          "FREQ=WEEKLY;BYDAY=2TU",
          "FREQ=WEEKLY;BYDAY=MO,FR;BYSETPOS=1",
          "FREQ=DAILY;INTERVAL=2;BYDAY=MO,TU",
          "FREQ=DAILY;BYMONTH=6",
          "FREQ=WEEKLY;BYHOUR=9,17"
        ] do
      test "refuses #{rrule} rather than write other dates" do
        assert RecurrenceConverter.rrule_to_outlook(unquote(rrule), @start_date) ==
                 {:error, :rule_not_supported_by_outlook}
      end
    end

    test "still writes no recurrence for no rule, or one without a readable FREQ" do
      assert RecurrenceConverter.rrule_to_outlook(nil, @start_date) == {:ok, nil}
      assert RecurrenceConverter.rrule_to_outlook("COUNT=3", @start_date) == {:ok, nil}
    end
  end

  describe "outlook_to_rrule/1 — relative patterns" do
    @range %{"type" => "noEnd", "startDate" => "2026-06-09"}

    test "reads a relative monthly pattern as a counted weekday" do
      pattern = %{
        "type" => "relativeMonthly",
        "interval" => 1,
        "daysOfWeek" => ["Tuesday"],
        "index" => "second"
      }

      assert RecurrenceConverter.outlook_to_rrule(%{"pattern" => pattern, "range" => @range}) ==
               "FREQ=MONTHLY;BYDAY=2TU"
    end

    test "reads a pattern without an index as the first, as Graph does" do
      pattern = %{"type" => "relativeMonthly", "interval" => 1, "daysOfWeek" => ["monday"]}

      assert RecurrenceConverter.outlook_to_rrule(%{"pattern" => pattern, "range" => @range}) ==
               "FREQ=MONTHLY;BYDAY=1MO"
    end

    test "reads nothing it cannot place, rather than another rule" do
      for pattern <- [
            %{"type" => "relativeMonthly", "daysOfWeek" => ["tuesday"], "index" => "fifth"},
            %{"type" => "relativeMonthly", "daysOfWeek" => ["someday"], "index" => "first"},
            %{"type" => "relativeMonthly", "index" => "first"},
            %{"type" => "relativeYearly", "daysOfWeek" => ["monday"], "index" => "first"}
          ] do
        assert RecurrenceConverter.outlook_to_rrule(%{"pattern" => pattern, "range" => @range}) ==
                 nil
      end
    end
  end

  describe "rrule_to_outlook/3 — endDate is the organiser's local date" do
    # Graph reads `endDate` as a local date in the event's own timezone (its
    # default when no `recurrenceTimeZone` is sent, which this converter never
    # sends), while a timed rule's UNTIL is an instant in UTC. Parsing the rule
    # without the zone read that instant as a UTC date, so an organiser west of
    # UTC had the series written one day late and Graph generated an extra
    # occurrence.
    for {timezone, until} <- [
          {"America/Los_Angeles", "20270101T075959Z"},
          {"America/New_York", "20270101T045959Z"},
          {"Europe/Tallinn", "20261231T215959Z"},
          {"Pacific/Auckland", "20261231T105959Z"},
          {"Etc/UTC", "20261231T235959Z"}
        ] do
      test "#{timezone} ends on the date the organiser picked" do
        rrule = "FREQ=DAILY;UNTIL=#{unquote(until)}"

        %{"range" => range} =
          to_outlook(rrule, @start_date, unquote(timezone))

        assert range["endDate"] == "2026-12-31"
      end
    end

    test "a rule built for a zone converts back to the date that built it" do
      for timezone <- ["America/Los_Angeles", "Europe/Tallinn", "Pacific/Auckland"] do
        rrule = RRule.build(%{freq: :daily, until: ~D[2026-12-31]}, timezone: timezone)

        %{"range" => range} =
          to_outlook(rrule, @start_date, timezone)

        assert range["endDate"] == "2026-12-31", "wrong endDate for #{timezone}"
      end
    end

    test "a legacy UTC-stamped rule keeps its date in every zone" do
      for timezone <- ["America/Los_Angeles", "Europe/Tallinn", "Pacific/Auckland", nil] do
        %{"range" => range} =
          to_outlook(
            "FREQ=DAILY;UNTIL=20261231T235959Z",
            @start_date,
            timezone
          )

        assert range["endDate"] == "2026-12-31", "wrong endDate for #{inspect(timezone)}"
      end
    end
  end

  # The dates up to 14 July 2026 of a Sunday-and-Monday fortnightly Graph
  # pattern starting on Monday 15 June, read back as an RRULE.
  defp expand_read_back(first_day_of_week) do
    rule =
      RecurrenceConverter.outlook_to_rrule(%{
        "pattern" => %{
          "type" => "weekly",
          "interval" => 2,
          "daysOfWeek" => ["sunday", "monday"],
          "firstDayOfWeek" => first_day_of_week
        },
        "range" => %{"type" => "noEnd", "startDate" => "2026-06-15"}
      })

    %{
      start_time: ~U[2026-06-15 09:00:00Z],
      end_time: ~U[2026-06-15 10:00:00Z],
      recurrence_rule: rule
    }
    |> RecurrenceExpander.expand(~U[2026-06-15 00:00:00Z], ~U[2026-07-14 23:59:59Z])
    |> Enum.map(&DateTime.to_date(&1.start_time))
  end

  # Every rule here has a Graph pattern; refusals are asserted directly.
  defp to_outlook(rrule, start_date, timezone \\ nil) do
    {:ok, recurrence} = RecurrenceConverter.rrule_to_outlook(rrule, start_date, timezone)
    recurrence
  end
end
