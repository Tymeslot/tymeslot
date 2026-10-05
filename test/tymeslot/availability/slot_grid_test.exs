defmodule Tymeslot.Availability.SlotGridTest do
  @moduledoc """
  The spec's worked examples for slots that cross midnight
  (`specs/2026-10-05-overnight-availability-design.md`), on in-memory
  schedules. 2027-06-14 is a Monday.
  """

  use ExUnit.Case, async: true

  @moduletag :availability
  @moduletag :unit

  import Tymeslot.Test.SlotGridHelpers

  alias Tymeslot.Availability.SlotGrid

  @mon ~D[2027-06-14]
  @tue ~D[2027-06-15]

  defp night(day, start_time, end_time, extra \\ %{}) do
    Map.merge(
      %{day_of_week: day, start_time: start_time, end_time: end_time, ends_next_day: true},
      extra
    )
  end

  defp day(day, start_time, end_time, extra \\ %{}) do
    Map.merge(%{day_of_week: day, start_time: start_time, end_time: end_time}, extra)
  end

  describe "overnight windows across DST nights" do
    test "Europe/London spring forward: the missing hour is never offered" do
      config = pure_config(days: [night(6, ~T[22:00:00], ~T[06:00:00])])

      assert labels(~D[2027-03-27], 60, "Europe/London", "Europe/London", config) ==
               ["10:00 PM", "11:00 PM"]

      assert labels(~D[2027-03-28], 60, "Europe/London", "Europe/London", config) ==
               ["12:00 AM", "2:00 AM", "3:00 AM", "4:00 AM", "5:00 AM"]
    end

    test "America/New_York fall back: a start only on the repeated hour's second pass is not offered" do
      # 100-minute steps from 23:00 EDT: 00:40 EDT, then 01:20 EST, whose
      # label the booking path would read as 01:20 EDT, an hour earlier.
      config = pure_config(days: [night(6, ~T[23:00:00], ~T[05:00:00])])

      assert labels(~D[2027-11-07], 100, "America/New_York", "America/New_York", config) ==
               ["12:40 AM", "3:00 AM"]
    end

    test "America/New_York fall back: the repeated hour is offered once, at its first occurrence" do
      config = pure_config(days: [night(6, ~T[23:00:00], ~T[03:00:00])])

      assert labels(~D[2027-11-06], 60, "America/New_York", "America/New_York", config) == [
               "11:00 PM"
             ]

      {:ok, starts} =
        SlotGrid.starts_for_date(
          ~D[2027-11-07],
          60,
          "America/New_York",
          "America/New_York",
          config
        )

      assert Enum.map(starts, &DateTime.to_iso8601/1) == [
               "2027-11-07T00:00:00-04:00",
               "2027-11-07T01:00:00-04:00",
               "2027-11-07T02:00:00-05:00"
             ]
    end
  end

  describe "bookers in another timezone" do
    test "far east: the slot ending at the booker's midnight is offered (today it is dropped)" do
      config = pure_config(days: [day(1, ~T[09:00:00], ~T[17:00:00])])

      assert labels(@mon, 60, "Europe/London", "Asia/Tokyo", config) ==
               ["5:00 PM", "6:00 PM", "7:00 PM", "8:00 PM", "9:00 PM", "10:00 PM", "11:00 PM"]

      assert labels(@tue, 60, "Europe/London", "Asia/Tokyo", config) == ["12:00 AM"]
    end

    test "far west: the grid continues from the window's start through the booker's midnight" do
      config = pure_config(days: [day(1, ~T[09:00:00], ~T[17:00:00])])

      assert labels(~D[2027-06-13], 45, "Asia/Kolkata", "America/Los_Angeles", config) ==
               ["8:30 PM", "9:15 PM", "10:00 PM", "10:45 PM", "11:30 PM"]

      # Today: 12:00, 12:45, 1:30, 2:15, 3:00, 3:45 AM (the grid restarted at midnight).
      assert labels(@mon, 45, "Asia/Kolkata", "America/Los_Angeles", config) ==
               ["12:15 AM", "1:00 AM", "1:45 AM", "2:30 AM", "3:15 AM"]
    end

    test "far west with an interval that divides the hour: only additions" do
      config = pure_config(days: [day(1, ~T[09:00:00], ~T[17:00:00])], interval: 30)

      assert labels(~D[2027-06-13], 60, "Asia/Kolkata", "America/Los_Angeles", config) ==
               ["8:30 PM", "9:00 PM", "9:30 PM", "10:00 PM", "10:30 PM", "11:00 PM", "11:30 PM"]

      assert labels(@mon, 60, "Asia/Kolkata", "America/Los_Angeles", config) ==
               [
                 "12:00 AM",
                 "12:30 AM",
                 "1:00 AM",
                 "1:30 AM",
                 "2:00 AM",
                 "2:30 AM",
                 "3:00 AM",
                 "3:30 AM"
               ]
    end
  end

  describe "a 24/7 schedule" do
    setup do
      %{
        config:
          pure_config(
            days:
              every_day(%{start_time: ~T[00:00:00], end_time: ~T[00:00:00], ends_next_day: true})
          )
      }
    end

    test "offers a 24-hour meeting every day", %{config: config} do
      assert labels(@mon, 1440, "Europe/Berlin", "Europe/Berlin", config) == ["12:00 AM"]
    end

    test "offers a 24-hour meeting at every grid time", %{config: config} do
      slots =
        labels(@mon, 1440, "Europe/Berlin", "Europe/Berlin", %{config | slot_interval_minutes: 30})

      assert length(slots) == 48
      assert List.first(slots) == "12:00 AM"
      assert List.last(slots) == "11:30 PM"
    end

    test "on a 23-hour day the grid follows elapsed time and skips the missing hour", %{
      config: config
    } do
      slots =
        labels(~D[2027-03-28], 1440, "Europe/Berlin", "Europe/Berlin", %{
          config
          | slot_interval_minutes: 30
        })

      assert length(slots) == 46
      assert "3:00 AM" in slots
      refute "2:00 AM" in slots
    end

    test "on a 25-hour day the duration-locked grid steps a full day and lists a second start",
         %{config: config} do
      # Sunday's window runs 25 elapsed hours, so a 24-hour step from its
      # 00:00 start lands at 23:00 the same day, still inside the window.
      assert labels(~D[2027-10-31], 1440, "Europe/Berlin", "Europe/Berlin", config) ==
               ["12:00 AM", "11:00 PM"]
    end
  end

  describe "breaks" do
    test "a break after midnight inside an overnight window" do
      config =
        pure_config(
          days: [
            night(5, ~T[22:00:00], ~T[04:00:00], %{
              breaks: [%{start_time: ~T[01:00:00], end_time: ~T[01:30:00]}]
            })
          ]
        )

      assert labels(~D[2027-06-18], 60, "Europe/London", "Europe/London", config) == [
               "10:00 PM",
               "11:00 PM"
             ]

      assert labels(~D[2027-06-19], 60, "Europe/London", "Europe/London", config) == [
               "12:00 AM",
               "2:00 AM",
               "3:00 AM"
             ]
    end

    test "a break blocks clock time across joined days" do
      config =
        pure_config(
          days: [
            night(1, ~T[00:00:00], ~T[00:00:00]),
            night(2, ~T[00:00:00], ~T[00:00:00], %{
              breaks: [%{start_time: ~T[01:00:00], end_time: ~T[02:00:00]}]
            })
          ],
          interval: 60
        )

      slots = labels(@mon, 240, "Europe/London", "Europe/London", config)

      assert "9:00 PM" in slots
      refute "10:00 PM" in slots
      refute "11:00 PM" in slots
    end

    test "a stale break outside its own window never blocks a neighbouring day's hours" do
      config =
        pure_config(
          days: [
            night(7, ~T[22:00:00], ~T[09:00:00]),
            day(1, ~T[09:00:00], ~T[17:00:00], %{
              breaks: [%{start_time: ~T[07:00:00], end_time: ~T[08:00:00]}]
            })
          ]
        )

      assert "7:00 AM" in labels(@mon, 60, "Europe/London", "Europe/London", config)
    end
  end

  describe "overrides and time off next to an overnight window" do
    setup do
      %{days: [night(1, ~T[22:00:00], ~T[02:00:00]), day(2, ~T[09:00:00], ~T[17:00:00])]}
    end

    test "unavailable on Tuesday keeps Monday's tail", %{days: days} do
      config = pure_config(days: days, overrides: [%{date: @tue, override_type: "unavailable"}])

      assert labels(@mon, 60, "Europe/London", "Europe/London", config) == [
               "10:00 PM",
               "11:00 PM"
             ]

      assert labels(@tue, 60, "Europe/London", "Europe/London", config) == ["12:00 AM", "1:00 AM"]
    end

    test "unavailable on Monday removes the whole overnight window", %{days: days} do
      config = pure_config(days: days, overrides: [%{date: @mon, override_type: "unavailable"}])

      assert labels(@mon, 60, "Europe/London", "Europe/London", config) == []
      assert List.first(labels(@tue, 60, "Europe/London", "Europe/London", config)) == "9:00 AM"
    end

    test "all-day time off on Tuesday blocks Monday's tail too", %{days: days} do
      config =
        pure_config(
          days: days,
          time_off: [%{starts_on: @tue, ends_on: @tue, start_time: nil, end_time: nil}]
        )

      assert labels(@mon, 60, "Europe/London", "Europe/London", config) == [
               "10:00 PM",
               "11:00 PM"
             ]

      assert labels(@tue, 60, "Europe/London", "Europe/London", config) == []
    end

    test "custom hours may end the next day" do
      config =
        pure_config(
          days: [],
          overrides: [
            %{
              date: ~D[2027-06-16],
              override_type: "custom_hours",
              start_time: ~T[20:00:00],
              end_time: ~T[01:00:00],
              ends_next_day: true
            }
          ]
        )

      assert labels(~D[2027-06-16], 60, "Europe/London", "Europe/London", config) ==
               ["8:00 PM", "9:00 PM", "10:00 PM", "11:00 PM"]

      assert labels(~D[2027-06-17], 60, "Europe/London", "Europe/London", config) == ["12:00 AM"]
    end
  end

  test "touching and overlapping windows join into one stretch" do
    config =
      pure_config(
        days: [night(1, ~T[22:00:00], ~T[02:00:00]), day(2, ~T[01:00:00], ~T[09:00:00])]
      )

    assert labels(@mon, 180, "Europe/London", "Europe/London", config) == ["10:00 PM"]
    assert labels(@tue, 180, "Europe/London", "Europe/London", config) == ["1:00 AM", "4:00 AM"]
  end

  test "a row whose end is not after its start, unflagged, still offers nothing" do
    config = pure_config(days: [day(1, ~T[17:00:00], ~T[09:00:00])])

    assert labels(@mon, 60, "Europe/London", "Europe/London", config) == []
    assert labels(@tue, 60, "Europe/London", "Europe/London", config) == []
  end

  test "an unknown booker timezone is an error, not an empty day" do
    config = pure_config(days: [day(1, ~T[09:00:00], ~T[17:00:00])])

    assert {:error, _reason} =
             SlotGrid.starts_for_date(@mon, 60, "Europe/London", "Mars/Olympus", config)
  end

  describe "an interval that is not a positive step" do
    # Without the guard the grid never advances and the test runs out of time
    # (or memory) instead of failing on the assertion.
    @describetag timeout: 2_000

    for interval <- [0, -15] do
      test "offers nothing rather than looping (interval #{interval})" do
        config =
          pure_config(days: [day(1, ~T[09:00:00], ~T[17:00:00])], interval: unquote(interval))

        assert labels(@mon, 60, "Europe/London", "Europe/London", config) == []
      end
    end
  end
end
