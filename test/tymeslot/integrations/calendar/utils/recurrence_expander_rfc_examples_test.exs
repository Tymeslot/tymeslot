defmodule Tymeslot.Integrations.Calendar.RecurrenceExpanderRfcExamplesTest do
  # The worked examples of RFC 5545 §3.8.5.3, for every rule part the
  # expander follows. Each series starts at 09:00 in America/New_York, as the
  # RFC's do, so the table also checks that every occurrence keeps 09:00
  # local across the October 1997 change back to EST. Examples that need a
  # part the expander does not follow (BYYEARDAY, BYWEEKNO, BYHOUR,
  # BYMINUTE) are left out.
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  @zone "America/New_York"

  @january_days for year <- 1998..2000, day <- 1..31, do: Date.new!(year, 1, day)

  @tuesdays_thursdays [
    ~D[1997-09-02],
    ~D[1997-09-04],
    ~D[1997-09-09],
    ~D[1997-09-11],
    ~D[1997-09-16],
    ~D[1997-09-18],
    ~D[1997-09-23],
    ~D[1997-09-25],
    ~D[1997-09-30],
    ~D[1997-10-02]
  ]

  # {example, first day, rule, last day of the range, expected dates}
  @examples [
    {"daily for 10 occurrences", ~D[1997-09-02], "FREQ=DAILY;COUNT=10", ~D[1997-12-31],
     Enum.to_list(Date.range(~D[1997-09-02], ~D[1997-09-11]))},
    {"daily until 24 December 1997", ~D[1997-09-02], "FREQ=DAILY;UNTIL=19971224T000000Z",
     ~D[1998-12-31], Enum.to_list(Date.range(~D[1997-09-02], ~D[1997-12-23]))},
    {"every 10 days, 5 occurrences", ~D[1997-09-02], "FREQ=DAILY;INTERVAL=10;COUNT=5",
     ~D[1997-12-31],
     [~D[1997-09-02], ~D[1997-09-12], ~D[1997-09-22], ~D[1997-10-02], ~D[1997-10-12]]},
    {"every day in January, for 3 years (yearly)", ~D[1998-01-01],
     "FREQ=YEARLY;UNTIL=20000131T140000Z;BYMONTH=1;BYDAY=SU,MO,TU,WE,TH,FR,SA", ~D[2000-12-31],
     @january_days},
    {"every day in January, for 3 years (daily)", ~D[1998-01-01],
     "FREQ=DAILY;UNTIL=20000131T140000Z;BYMONTH=1", ~D[2000-12-31], @january_days},
    {"weekly for 10 occurrences", ~D[1997-09-02], "FREQ=WEEKLY;COUNT=10", ~D[1997-12-31],
     Enum.to_list(Date.range(~D[1997-09-02], ~D[1997-11-04], 7))},
    {"weekly until 24 December 1997", ~D[1997-09-02], "FREQ=WEEKLY;UNTIL=19971224T000000Z",
     ~D[1998-12-31], Enum.to_list(Date.range(~D[1997-09-02], ~D[1997-12-23], 7))},
    {"every other week", ~D[1997-09-02], "FREQ=WEEKLY;INTERVAL=2;WKST=SU", ~D[1997-11-30],
     Enum.to_list(Date.range(~D[1997-09-02], ~D[1997-11-25], 14))},
    {"weekly on Tuesday and Thursday for five weeks (UNTIL)", ~D[1997-09-02],
     "FREQ=WEEKLY;UNTIL=19971007T000000Z;WKST=SU;BYDAY=TU,TH", ~D[1997-12-31],
     @tuesdays_thursdays},
    {"weekly on Tuesday and Thursday for five weeks (COUNT)", ~D[1997-09-02],
     "FREQ=WEEKLY;COUNT=10;WKST=SU;BYDAY=TU,TH", ~D[1997-12-31], @tuesdays_thursdays},
    {"every other week on Monday, Wednesday and Friday until 24 December 1997", ~D[1997-09-02],
     "FREQ=WEEKLY;INTERVAL=2;UNTIL=19971224T000000Z;WKST=SU;BYDAY=MO,WE,FR", ~D[1998-12-31],
     [
       ~D[1997-09-02],
       ~D[1997-09-03],
       ~D[1997-09-05],
       ~D[1997-09-15],
       ~D[1997-09-17],
       ~D[1997-09-19],
       ~D[1997-09-29],
       ~D[1997-10-01],
       ~D[1997-10-03],
       ~D[1997-10-13],
       ~D[1997-10-15],
       ~D[1997-10-17],
       ~D[1997-10-27],
       ~D[1997-10-29],
       ~D[1997-10-31],
       ~D[1997-11-10],
       ~D[1997-11-12],
       ~D[1997-11-14],
       ~D[1997-11-24],
       ~D[1997-11-26],
       ~D[1997-11-28],
       ~D[1997-12-08],
       ~D[1997-12-10],
       ~D[1997-12-12],
       ~D[1997-12-22]
     ]},
    {"every other week on Tuesday and Thursday, for 8 occurrences", ~D[1997-09-02],
     "FREQ=WEEKLY;INTERVAL=2;COUNT=8;WKST=SU;BYDAY=TU,TH", ~D[1997-12-31],
     [
       ~D[1997-09-02],
       ~D[1997-09-04],
       ~D[1997-09-16],
       ~D[1997-09-18],
       ~D[1997-09-30],
       ~D[1997-10-02],
       ~D[1997-10-14],
       ~D[1997-10-16]
     ]},
    {"monthly on the first Friday for 10 occurrences", ~D[1997-09-05],
     "FREQ=MONTHLY;COUNT=10;BYDAY=1FR", ~D[1998-12-31],
     [
       ~D[1997-09-05],
       ~D[1997-10-03],
       ~D[1997-11-07],
       ~D[1997-12-05],
       ~D[1998-01-02],
       ~D[1998-02-06],
       ~D[1998-03-06],
       ~D[1998-04-03],
       ~D[1998-05-01],
       ~D[1998-06-05]
     ]},
    {"monthly on the first Friday until 24 December 1997", ~D[1997-09-05],
     "FREQ=MONTHLY;UNTIL=19971224T000000Z;BYDAY=1FR", ~D[1998-12-31],
     [~D[1997-09-05], ~D[1997-10-03], ~D[1997-11-07], ~D[1997-12-05]]},
    {"every other month on the first and last Sunday, for 10 occurrences", ~D[1997-09-07],
     "FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU", ~D[1998-12-31],
     [
       ~D[1997-09-07],
       ~D[1997-09-28],
       ~D[1997-11-02],
       ~D[1997-11-30],
       ~D[1998-01-04],
       ~D[1998-01-25],
       ~D[1998-03-01],
       ~D[1998-03-29],
       ~D[1998-05-03],
       ~D[1998-05-31]
     ]},
    {"monthly on the second-to-last Monday for 6 months", ~D[1997-09-22],
     "FREQ=MONTHLY;COUNT=6;BYDAY=-2MO", ~D[1998-12-31],
     [
       ~D[1997-09-22],
       ~D[1997-10-20],
       ~D[1997-11-17],
       ~D[1997-12-22],
       ~D[1998-01-19],
       ~D[1998-02-16]
     ]},
    {"monthly on the third-to-last day of the month", ~D[1997-09-28],
     "FREQ=MONTHLY;BYMONTHDAY=-3", ~D[1998-02-28],
     [
       ~D[1997-09-28],
       ~D[1997-10-29],
       ~D[1997-11-28],
       ~D[1997-12-29],
       ~D[1998-01-29],
       ~D[1998-02-26]
     ]},
    {"monthly on the 2nd and 15th for 10 occurrences", ~D[1997-09-02],
     "FREQ=MONTHLY;COUNT=10;BYMONTHDAY=2,15", ~D[1998-12-31],
     [
       ~D[1997-09-02],
       ~D[1997-09-15],
       ~D[1997-10-02],
       ~D[1997-10-15],
       ~D[1997-11-02],
       ~D[1997-11-15],
       ~D[1997-12-02],
       ~D[1997-12-15],
       ~D[1998-01-02],
       ~D[1998-01-15]
     ]},
    {"monthly on the first and last day for 10 occurrences", ~D[1997-09-30],
     "FREQ=MONTHLY;COUNT=10;BYMONTHDAY=1,-1", ~D[1998-12-31],
     [
       ~D[1997-09-30],
       ~D[1997-10-01],
       ~D[1997-10-31],
       ~D[1997-11-01],
       ~D[1997-11-30],
       ~D[1997-12-01],
       ~D[1997-12-31],
       ~D[1998-01-01],
       ~D[1998-01-31],
       ~D[1998-02-01]
     ]},
    {"every 18 months on the 10th to 15th, for 10 occurrences", ~D[1997-09-10],
     "FREQ=MONTHLY;INTERVAL=18;COUNT=10;BYMONTHDAY=10,11,12,13,14,15", ~D[1999-12-31],
     Enum.to_list(Date.range(~D[1997-09-10], ~D[1997-09-15])) ++
       Enum.to_list(Date.range(~D[1999-03-10], ~D[1999-03-13]))},
    {"every Tuesday, every other month", ~D[1997-09-02], "FREQ=MONTHLY;INTERVAL=2;BYDAY=TU",
     ~D[1998-03-31],
     [
       ~D[1997-09-02],
       ~D[1997-09-09],
       ~D[1997-09-16],
       ~D[1997-09-23],
       ~D[1997-09-30],
       ~D[1997-11-04],
       ~D[1997-11-11],
       ~D[1997-11-18],
       ~D[1997-11-25],
       ~D[1998-01-06],
       ~D[1998-01-13],
       ~D[1998-01-20],
       ~D[1998-01-27],
       ~D[1998-03-03],
       ~D[1998-03-10],
       ~D[1998-03-17],
       ~D[1998-03-24],
       ~D[1998-03-31]
     ]},
    {"yearly in June and July for 10 occurrences", ~D[1997-06-10],
     "FREQ=YEARLY;COUNT=10;BYMONTH=6,7", ~D[2002-12-31],
     for(year <- 1997..2001, month <- [6, 7], do: Date.new!(year, month, 10))},
    {"every other year in January, February and March for 10 occurrences", ~D[1997-03-10],
     "FREQ=YEARLY;INTERVAL=2;COUNT=10;BYMONTH=1,2,3", ~D[2004-12-31],
     [~D[1997-03-10]] ++
       for(year <- [1999, 2001, 2003], month <- 1..3, do: Date.new!(year, month, 10))},
    {"every 20th Monday of the year", ~D[1997-05-19], "FREQ=YEARLY;BYDAY=20MO", ~D[1999-12-31],
     [~D[1997-05-19], ~D[1998-05-18], ~D[1999-05-17]]},
    {"every Thursday in March", ~D[1997-03-13], "FREQ=YEARLY;BYMONTH=3;BYDAY=TH", ~D[1999-12-31],
     [
       ~D[1997-03-13],
       ~D[1997-03-20],
       ~D[1997-03-27],
       ~D[1998-03-05],
       ~D[1998-03-12],
       ~D[1998-03-19],
       ~D[1998-03-26],
       ~D[1999-03-04],
       ~D[1999-03-11],
       ~D[1999-03-18],
       ~D[1999-03-25]
     ]},
    {"every Thursday, but only during June, July and August", ~D[1997-06-05],
     "FREQ=YEARLY;BYDAY=TH;BYMONTH=6,7,8", ~D[1997-12-31],
     Enum.to_list(Date.range(~D[1997-06-05], ~D[1997-08-28], 7))},
    {"the first Saturday that follows the first Sunday of the month", ~D[1997-09-13],
     "FREQ=MONTHLY;BYDAY=SA;BYMONTHDAY=7,8,9,10,11,12,13", ~D[1998-06-30],
     [
       ~D[1997-09-13],
       ~D[1997-10-11],
       ~D[1997-11-08],
       ~D[1997-12-13],
       ~D[1998-01-10],
       ~D[1998-02-07],
       ~D[1998-03-07],
       ~D[1998-04-11],
       ~D[1998-05-09],
       ~D[1998-06-13]
     ]},
    {"US presidential election day", ~D[1996-11-05],
     "FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=TU;BYMONTHDAY=2,3,4,5,6,7,8", ~D[2004-12-31],
     [~D[1996-11-05], ~D[2000-11-07], ~D[2004-11-02]]},
    {"the third instance of Tuesday, Wednesday or Thursday, for the next 3 months",
     ~D[1997-09-04], "FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3", ~D[1998-12-31],
     [~D[1997-09-04], ~D[1997-10-07], ~D[1997-11-06]]},
    {"the second-to-last weekday of the month", ~D[1997-09-29],
     "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2", ~D[1998-03-31],
     [
       ~D[1997-09-29],
       ~D[1997-10-30],
       ~D[1997-11-27],
       ~D[1997-12-30],
       ~D[1998-01-29],
       ~D[1998-02-26],
       ~D[1998-03-30]
     ]},
    {"WKST=MO changes which Sunday a fortnightly week holds", ~D[1997-08-05],
     "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO", ~D[1997-12-31],
     [~D[1997-08-05], ~D[1997-08-10], ~D[1997-08-19], ~D[1997-08-24]]},
    {"WKST=SU changes which Sunday a fortnightly week holds", ~D[1997-08-05],
     "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU", ~D[1997-12-31],
     [~D[1997-08-05], ~D[1997-08-17], ~D[1997-08-19], ~D[1997-08-31]]},
    {"an invalid date (30 February) is skipped, not counted", ~D[2007-01-15],
     "FREQ=MONTHLY;BYMONTHDAY=15,30;COUNT=5", ~D[2007-12-31],
     [~D[2007-01-15], ~D[2007-01-30], ~D[2007-02-15], ~D[2007-03-15], ~D[2007-03-30]]}
  ]

  for {name, first_day, rule, last_day, expected} <- @examples do
    @first_day first_day
    @rule rule
    @last_day last_day
    @expected expected

    test "RFC 5545 example: #{name}" do
      occurrences = expand(@rule, @first_day, @last_day)

      assert Enum.map(occurrences, &DateTime.to_date/1) == @expected
      assert Enum.reject(occurrences, &(DateTime.to_time(&1) == ~T[09:00:00])) == []
    end
  end

  test "RFC 5545 example: every Friday the 13th, excluding the first start" do
    first = DateTime.new!(~D[1997-09-02], ~T[09:00:00], @zone)

    starts =
      expand("FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13", ~D[1997-09-02], ~D[2000-12-31],
        exdates: [first]
      )

    assert Enum.map(starts, &DateTime.to_date/1) ==
             [~D[1998-02-13], ~D[1998-03-13], ~D[1998-11-13], ~D[1999-08-13], ~D[2000-10-13]]
  end

  # The occurrences' starts, in the series' zone.
  defp expand(rule, first_day, last_day, opts \\ []) do
    %{
      start_time: DateTime.new!(first_day, ~T[09:00:00], @zone),
      end_time: DateTime.new!(first_day, ~T[10:00:00], @zone),
      recurrence_rule: rule
    }
    |> RecurrenceExpander.expand(
      DateTime.new!(first_day, ~T[00:00:00], @zone),
      DateTime.new!(last_day, ~T[23:59:59], @zone),
      opts
    )
    |> Enum.map(&DateTime.shift_zone!(&1.start_time, @zone))
  end
end
