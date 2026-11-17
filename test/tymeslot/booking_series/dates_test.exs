defmodule Tymeslot.BookingSeries.DatesTest do
  @moduledoc """
  A recurring series keeps the host's wall-clock time and, monthly, the
  weekday ordinal of its first date, whatever DST and month lengths do.
  """

  use ExUnit.Case, async: true

  @moduletag :bookings
  @moduletag :unit

  alias Tymeslot.BookingSeries.Dates

  defp utc(naive, tz), do: naive |> DateTime.from_naive!(tz) |> DateTime.shift_zone!("Etc/UTC")
  defp local(starts, tz), do: Enum.map(starts, &DateTime.shift_zone!(&1, tz))

  test "weekly keeps the local time across the spring DST change" do
    tz = "Europe/Berlin"
    first = utc(~N[2027-03-18 17:00:00], tz)

    starts = Dates.recurring_starts(first, :weekly, 1, 3, tz)

    assert hd(starts) == first
    assert Enum.at(starts, 2) == ~U[2027-04-01 15:00:00Z]

    assert Enum.map(local(starts, tz), &DateTime.to_naive/1) == [
             ~N[2027-03-18 17:00:00],
             ~N[2027-03-25 17:00:00],
             ~N[2027-04-01 17:00:00]
           ]
  end

  test "monthly keeps the weekday ordinal" do
    tz = "Etc/UTC"
    # The 2nd Thursday of January 2027.
    first = ~U[2027-01-14 10:00:00Z]

    assert Dates.recurring_starts(first, :monthly, 1, 3, tz) == [
             ~U[2027-01-14 10:00:00Z],
             ~U[2027-02-11 10:00:00Z],
             ~U[2027-03-11 10:00:00Z]
           ]
  end

  test "a fifth weekday falls back to the last" do
    tz = "Etc/UTC"
    # The 5th Friday of January 2027; February has four.
    first = ~U[2027-01-29 09:00:00Z]

    assert [_first, ~U[2027-02-26 09:00:00Z], ~U[2027-03-26 09:00:00Z]] =
             Dates.recurring_starts(first, :monthly, 1, 3, tz)
  end

  test "every other month steps two months" do
    assert Dates.recurring_starts(~U[2027-01-14 10:00:00Z], :monthly, 2, 2, "Etc/UTC") == [
             ~U[2027-01-14 10:00:00Z],
             ~U[2027-03-11 10:00:00Z]
           ]
  end

  test "every two weeks" do
    assert Dates.recurring_starts(~U[2027-01-04 09:00:00Z], :weekly, 2, 3, "Etc/UTC") == [
             ~U[2027-01-04 09:00:00Z],
             ~U[2027-01-18 09:00:00Z],
             ~U[2027-02-01 09:00:00Z]
           ]
  end

  test "daily steps the interval in days" do
    assert Dates.recurring_starts(~U[2027-01-04 09:00:00Z], :daily, 3, 3, "Etc/UTC") == [
             ~U[2027-01-04 09:00:00Z],
             ~U[2027-01-07 09:00:00Z],
             ~U[2027-01-10 09:00:00Z]
           ]
  end

  test "a local time skipped by DST shifts forward" do
    tz = "America/New_York"
    # 02:30 on 2027-03-14 does not exist in New York: the clocks jump to 03:00.
    first = utc(~N[2027-03-07 02:30:00], tz)

    starts = Dates.recurring_starts(first, :weekly, 1, 3, tz)

    assert Enum.map(local(starts, tz), &DateTime.to_naive/1) == [
             ~N[2027-03-07 02:30:00],
             ~N[2027-03-14 03:00:00],
             ~N[2027-03-21 02:30:00]
           ]
  end

  test "an ambiguous local time takes the earlier instant" do
    tz = "America/New_York"
    # 01:30 on 2027-11-07 happens twice; the first is still EDT (05:30 UTC).
    first = utc(~N[2027-10-31 01:30:00], tz)

    assert [_first, ~U[2027-11-07 05:30:00Z]] = Dates.recurring_starts(first, :weekly, 1, 2, tz)
  end
end
