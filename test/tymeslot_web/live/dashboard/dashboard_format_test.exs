defmodule TymeslotWeb.Dashboard.DashboardFormatTest do
  @moduledoc """
  Covers the dashboard's one vocabulary for dates, times and durations: the
  organiser's clock and timezone, the reader's language, and a time range that
  never wraps inside one of its ends.
  """

  use ExUnit.Case, async: true

  @moduletag :dashboard
  @moduletag :unit

  alias Tymeslot.Agenda.Entry
  alias TymeslotWeb.Dashboard.DashboardFormat

  @nbsp " "

  setup do
    on_exit(fn -> Gettext.put_locale(TymeslotWeb.Gettext, "en") end)
    :ok
  end

  defp entry(attrs) do
    struct!(
      %Entry{
        id: "e1",
        source: :external,
        title: "Standup",
        day: ~D[2026-02-05],
        start_at: ~U[2026-02-05 14:30:00Z],
        end_at: ~U[2026-02-05 15:00:00Z],
        all_day?: false
      },
      attrs
    )
  end

  describe "time_range/4" do
    test "uses a 12-hour clock with an en dash" do
      assert DashboardFormat.time_range(
               ~U[2026-02-05 11:00:00Z],
               ~U[2026-02-05 11:15:00Z],
               "Etc/UTC",
               "12h"
             ) == "11:00#{@nbsp}AM#{@nbsp}– 11:15#{@nbsp}AM"
    end

    test "uses a 24-hour clock when that is the organiser's choice" do
      assert DashboardFormat.time_range(
               ~U[2026-02-05 14:30:00Z],
               ~U[2026-02-05 15:00:00Z],
               "Etc/UTC",
               "24h"
             ) == "14:30#{@nbsp}– 15:00"
    end

    test "can only break after the dash" do
      range =
        DashboardFormat.time_range(
          ~U[2026-02-05 11:00:00Z],
          ~U[2026-02-05 11:15:00Z],
          "Etc/UTC",
          "12h"
        )

      assert [_one_line, _other_line] = String.split(range, " ")
      assert String.ends_with?(range |> String.split(" ") |> hd(), "–")
    end

    test "converts into the organiser's timezone" do
      assert DashboardFormat.time_range(
               ~U[2026-07-01 12:00:00Z],
               ~U[2026-07-01 13:00:00Z],
               "Europe/Berlin",
               "24h"
             ) == "14:00#{@nbsp}– 15:00"
    end

    test "names both days of a range that crosses local midnight" do
      # 21:30-23:30 UTC is 23:30-01:30 in Berlin (CEST): across midnight there,
      # though the same day in UTC.
      assert DashboardFormat.time_range(
               ~U[2026-07-01 21:30:00Z],
               ~U[2026-07-01 23:30:00Z],
               "Europe/Berlin",
               "24h"
             ) ==
               "Jul#{@nbsp}1,#{@nbsp}23:30#{@nbsp}– Jul#{@nbsp}2,#{@nbsp}01:30"
    end

    test "orders the dates of a cross-midnight range by the reader's language" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")

      assert DashboardFormat.time_range(
               ~U[2026-07-01 21:30:00Z],
               ~U[2026-07-01 23:30:00Z],
               "Etc/UTC",
               "24h"
             ) == "21:30#{@nbsp}– 23:30"

      assert DashboardFormat.time_range(
               ~U[2026-07-01 22:30:00Z],
               ~U[2026-07-02 00:30:00Z],
               "Etc/UTC",
               "24h"
             ) == "1.#{@nbsp}Jul,#{@nbsp}22:30#{@nbsp}– 2.#{@nbsp}Jul,#{@nbsp}00:30"
    end
  end

  describe "entry_time_range/3 and start_label/3" do
    test "an all-day entry reads as all day" do
      all_day = entry(all_day?: true)

      assert DashboardFormat.entry_time_range(all_day, "Etc/UTC", "12h") == "All day"
      assert DashboardFormat.start_label(all_day, "Etc/UTC", "12h") == "All day"
    end

    test "a timed entry gives its range, or its start alone" do
      timed = entry([])

      assert DashboardFormat.entry_time_range(timed, "Etc/UTC", "12h") ==
               "2:30#{@nbsp}PM#{@nbsp}– 3:00#{@nbsp}PM"

      assert DashboardFormat.start_label(timed, "Etc/UTC", "24h") == "14:30"
    end
  end

  describe "day_label/3" do
    # One fixed clock for the whole test: today, tomorrow and the entries are
    # all derived from `now`, never read from the wall clock.
    @now ~U[2026-02-05 23:30:00Z]

    defp on(date) do
      start = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")
      entry(day: date, start_at: start, end_at: DateTime.add(start, 1800))
    end

    test "says Today and Tomorrow, and a short date beyond" do
      assert DashboardFormat.day_label(on(~D[2026-02-05]), "Etc/UTC", @now) == "Today"
      assert DashboardFormat.day_label(on(~D[2026-02-06]), "Etc/UTC", @now) == "Tomorrow"
      assert DashboardFormat.day_label(on(~D[2026-02-08]), "Etc/UTC", @now) == "Sun Feb 8"
    end

    test "decides today in the organiser's timezone" do
      # 23:30 UTC on the 5th is already the 6th in Berlin.
      assert DashboardFormat.day_label(on(~D[2026-02-06]), "Europe/Berlin", @now) == "Today"
    end

    test "keeps an overnight entry still running as today's" do
      overnight =
        entry(
          day: ~D[2026-02-04],
          start_at: ~U[2026-02-04 22:00:00Z],
          end_at: ~U[2026-02-05 02:00:00Z]
        )

      assert DashboardFormat.day_label(overnight, "Etc/UTC", ~U[2026-02-05 01:00:00Z]) == "Today"
    end
  end

  describe "relative_date/2" do
    test "names today and tomorrow, and dates anything else" do
      assert DashboardFormat.relative_date(~D[2026-02-05], ~D[2026-02-05]) == "Today"
      assert DashboardFormat.relative_date(~D[2026-02-06], ~D[2026-02-05]) == "Tomorrow"
      assert DashboardFormat.relative_date(~D[2026-02-04], ~D[2026-02-05]) == "Wed Feb 4"
    end
  end

  describe "daylight saving and unknown zones" do
    test "a range across the spring-forward gap shows the clocks either side" do
      # 00:30-01:30 UTC on 29 March 2026 is 01:30 CET to 03:30 CEST in Berlin.
      assert DashboardFormat.time_range(
               ~U[2026-03-29 00:30:00Z],
               ~U[2026-03-29 01:30:00Z],
               "Europe/Berlin",
               "24h"
             ) == "01:30#{@nbsp}– 03:30"
    end

    test "a range across the autumn fall-back reads the repeated hour" do
      # 00:30-01:30 UTC on 25 October 2026 is 02:30 CEST to 02:30 CET in Berlin.
      assert DashboardFormat.time_range(
               ~U[2026-10-25 00:30:00Z],
               ~U[2026-10-25 01:30:00Z],
               "Europe/Berlin",
               "24h"
             ) == "02:30#{@nbsp}– 02:30"

      assert DashboardFormat.duration(~U[2026-10-25 00:30:00Z], ~U[2026-10-25 01:30:00Z]) ==
               "1 hr"
    end

    test "an unknown timezone falls back to UTC rather than crashing" do
      assert DashboardFormat.time_range(
               ~U[2026-02-05 14:30:00Z],
               ~U[2026-02-05 15:00:00Z],
               "Not/AZone",
               "24h"
             ) == "14:30#{@nbsp}– 15:00"

      assert DashboardFormat.local_date(~U[2026-02-05 23:30:00Z], "Not/AZone") == ~D[2026-02-05]
    end
  end

  describe "short_date/1 and long_date/1" do
    test "follow English order" do
      assert DashboardFormat.short_date(~D[2026-02-05]) == "Thu Feb 5"
      assert DashboardFormat.long_date(~D[2026-02-05]) == "Thursday, February 5, 2026"
    end

    test "follow German order" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")

      assert DashboardFormat.short_date(~D[2026-02-05]) == "Do 5. Feb"
      assert DashboardFormat.long_date(~D[2026-02-05]) == "Donnerstag, 5. Februar 2026"
    end
  end

  describe "date_label/2" do
    test "names the local date a timed entry starts on" do
      # 23:30 UTC on the 5th is already the 6th in Berlin.
      late = entry(start_at: ~U[2026-02-05 23:30:00Z], end_at: ~U[2026-02-06 00:00:00Z])

      assert DashboardFormat.date_label(late, "Europe/Berlin") == "Friday, February 6, 2026"
    end

    test "names the first and last days of a multi-day all-day entry" do
      leave =
        entry(
          all_day?: true,
          start_at: ~U[2026-02-02 00:00:00Z],
          end_at: ~U[2026-02-07 00:00:00Z]
        )

      assert DashboardFormat.date_label(leave, "Etc/UTC") ==
               String.replace("Monday, February 2, 2026", " ", @nbsp) <>
                 "#{@nbsp}– " <> String.replace("Friday, February 6, 2026", " ", @nbsp)
    end
  end

  describe "duration/1,2" do
    test "reads minutes, hours, and both" do
      assert DashboardFormat.duration(45) == "45 min"
      assert DashboardFormat.duration(120) == "2 hr"
      assert DashboardFormat.duration(90) == "1 hr 30 min"
    end

    test "is nothing for an empty or inverted span" do
      assert DashboardFormat.duration(0) == nil
      assert DashboardFormat.duration(~U[2026-02-05 10:00:00Z], ~U[2026-02-05 09:00:00Z]) == nil
    end

    test "measures a start and end" do
      assert DashboardFormat.duration(~U[2026-02-05 10:00:00Z], ~U[2026-02-05 10:45:00Z]) ==
               "45 min"
    end
  end

  describe "title/1" do
    test "keeps a title and labels a missing one" do
      assert DashboardFormat.title("Standup") == "Standup"
      assert DashboardFormat.title(nil) == "(No title)"
      assert DashboardFormat.title("") == "(No title)"
    end
  end
end
