defmodule Tymeslot.Availability.WindowTest do
  use ExUnit.Case, async: true

  @moduletag :availability
  @moduletag :unit

  alias Tymeslot.Availability.Window

  defp window(start_time, end_time, ends_next_day),
    do: %{start_time: start_time, end_time: end_time, ends_next_day: ends_next_day}

  describe "valid?/3" do
    test "a same-day window needs its end after its start" do
      assert Window.valid?(~T[09:00:00], ~T[17:00:00], false)
      refute Window.valid?(~T[17:00:00], ~T[09:00:00], false)
      refute Window.valid?(~T[09:00:00], ~T[09:00:00], false)
    end

    test "a next-day window needs its end at or before its start" do
      assert Window.valid?(~T[22:00:00], ~T[02:00:00], true)
      assert Window.valid?(~T[00:00:00], ~T[00:00:00], true)
      assert Window.valid?(~T[09:00:00], ~T[09:00:00], true)
      refute Window.valid?(~T[09:00:00], ~T[10:00:00], true)
    end
  end

  describe "span_seconds/1" do
    test "measures same-day and next-day windows" do
      assert Window.span_seconds(window(~T[09:00:00], ~T[17:00:00], false)) == 8 * 3600
      assert Window.span_seconds(window(~T[22:00:00], ~T[02:00:00], true)) == 4 * 3600
      assert Window.span_seconds(window(~T[00:00:00], ~T[00:00:00], true)) == 24 * 3600
    end
  end

  describe "break_within?/3" do
    test "keeps today's rule for a same-day window" do
      day = window(~T[09:00:00], ~T[17:00:00], false)

      assert Window.break_within?(day, ~T[12:00:00], ~T[13:00:00])
      assert Window.break_within?(day, ~T[09:00:00], ~T[17:00:00])
      refute Window.break_within?(day, ~T[08:30:00], ~T[09:30:00])
      refute Window.break_within?(day, ~T[16:30:00], ~T[17:30:00])
      refute Window.break_within?(day, ~T[13:00:00], ~T[12:00:00])
    end

    test "accepts breaks after midnight and across it inside an overnight window" do
      night = window(~T[22:00:00], ~T[04:00:00], true)

      assert Window.break_within?(night, ~T[01:00:00], ~T[01:30:00])
      assert Window.break_within?(night, ~T[23:30:00], ~T[00:30:00])
      assert Window.break_within?(night, ~T[22:00:00], ~T[04:00:00])
      refute Window.break_within?(night, ~T[21:00:00], ~T[22:30:00])
      refute Window.break_within?(night, ~T[03:30:00], ~T[04:30:00])
      refute Window.break_within?(night, ~T[02:00:00], ~T[01:00:00])
    end

    test "a break may end exactly as a 24-hour window ends" do
      full = window(~T[00:00:00], ~T[00:00:00], true)

      assert Window.break_within?(full, ~T[23:00:00], ~T[00:00:00])
      refute Window.break_within?(full, ~T[23:00:00], ~T[01:00:00])
    end
  end

  describe "resolve/3 and resolve_break/4" do
    test "puts a next-day end on the following date" do
      night = window(~T[22:00:00], ~T[02:00:00], true)

      assert Window.resolve(night, ~D[2027-06-14], "Europe/London") ==
               {DateTime.new!(~D[2027-06-14], ~T[22:00:00], "Europe/London"),
                DateTime.new!(~D[2027-06-15], ~T[02:00:00], "Europe/London")}
    end

    test "puts break times before the window's start on the following date" do
      night = window(~T[22:00:00], ~T[04:00:00], true)

      assert Window.resolve_break(night, {~T[23:30:00], ~T[00:30:00]}, ~D[2027-06-14], "Etc/UTC") ==
               {~U[2027-06-14 23:30:00Z], ~U[2027-06-15 00:30:00Z]}

      assert Window.resolve_break(night, {~T[01:00:00], ~T[01:30:00]}, ~D[2027-06-14], "Etc/UTC") ==
               {~U[2027-06-15 01:00:00Z], ~U[2027-06-15 01:30:00Z]}
    end

    test "a same-day window keeps every break on its own date, as today" do
      day = window(~T[09:00:00], ~T[17:00:00], false)

      assert Window.resolve_break(day, {~T[08:00:00], ~T[08:30:00]}, ~D[2027-06-14], "Etc/UTC") ==
               {~U[2027-06-14 08:00:00Z], ~U[2027-06-14 08:30:00Z]}
    end

    test "reads times to the minute" do
      day = window(~T[09:00:30], ~T[17:00:59], false)

      assert Window.resolve(day, ~D[2027-06-14], "Etc/UTC") ==
               {~U[2027-06-14 09:00:00Z], ~U[2027-06-14 17:00:00Z]}
    end

    test "a window opening in a spring-forward gap starts when the gap ends" do
      night = window(~T[01:30:00], ~T[01:30:00], true)

      {start_dt, end_dt} = Window.resolve(night, ~D[2027-03-28], "Europe/London")

      assert start_dt == DateTime.new!(~D[2027-03-28], ~T[02:00:00], "Europe/London")
      assert end_dt == DateTime.new!(~D[2027-03-29], ~T[01:30:00], "Europe/London")
    end
  end

  describe "a next-day window across the Europe/London autumn change" do
    test "resolves to its true six-hour length while its clock span reads five" do
      night = window(~T[22:00:00], ~T[03:00:00], true)

      {start_dt, end_dt} = Window.resolve(night, ~D[2026-10-24], "Europe/London")

      assert DateTime.to_iso8601(start_dt) == "2026-10-24T22:00:00+01:00"
      assert DateTime.to_iso8601(end_dt) == "2026-10-25T03:00:00+00:00"
      assert DateTime.diff(end_dt, start_dt, :hour) == 6
      assert Window.span_seconds(night) == 5 * 3600
    end
  end

  describe "the editor's wire format" do
    test "parse_end/1 reads a plain and a next-day end" do
      assert Window.parse_end("17:00") == {:ok, {~T[17:00:00], false}}
      assert Window.parse_end("02:00+1") == {:ok, {~T[02:00:00], true}}
      assert Window.parse_end("24:00") == {:error, :invalid_time_format}
      assert Window.parse_end("02:00+1+1") == {:error, :invalid_time_format}
    end

    test "format_end/2 is parse_end/1's inverse" do
      assert Window.format_end(~T[02:00:00], true) == "02:00+1"
      assert Window.format_end(~T[17:00:00], false) == "17:00"
      assert Window.format_end(nil, false) == ""
    end

    test "next_day?/3 tells which times in a window fall on the following day" do
      night = window(~T[22:00:00], ~T[02:00:00], true)

      refute Window.next_day?(night, ~T[23:00:00], :start)
      assert Window.next_day?(night, ~T[01:00:00], :start)
      refute Window.next_day?(night, ~T[23:30:00], :end)
      assert Window.next_day?(night, ~T[01:00:00], :end)
      # A break ending exactly at midnight ends on the next day.
      assert Window.next_day?(night, ~T[00:00:00], :end)
      refute Window.next_day?(window(~T[09:00:00], ~T[17:00:00], false), ~T[08:00:00], :start)
    end
  end
end
