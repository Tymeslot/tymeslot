defmodule TymeslotWeb.Components.Shared.TimeOptionsTest do
  use ExUnit.Case, async: true

  @moduletag :availability
  @moduletag :components

  alias TymeslotWeb.Components.Shared.TimeOptions

  describe "end_options/3" do
    test "offers every quarter hour after the start, then the next day through the start again" do
      options = TimeOptions.end_options(~T[22:00:00], "24h", "02:00+1")

      assert length(options) == 96
      assert List.first(options) == {"22:15", "22:15"}
      assert {"23:45", "23:45"} in options
      assert {"00:00 (+1)", "00:00+1"} in options
      assert {"02:00 (+1)", "02:00+1"} in options
      assert List.last(options) == {"22:00 (+1)", "22:00+1"}
    end

    test "labels follow the organiser's clock while values stay 24h" do
      options = TimeOptions.end_options(~T[22:00:00], "12h", "02:00+1")

      assert {"2:00 AM (+1)", "02:00+1"} in options
      assert {"10:15 PM", "22:15"} in options
    end

    test "a day starting at midnight can end at midnight the next day, 24 hours" do
      assert List.last(TimeOptions.end_options(~T[00:00:00], "24h", "17:00")) ==
               {"00:00 (+1)", "00:00+1"}
    end

    test "a start off the quarter-hour grid can still be followed by a full 24 hours" do
      options = TimeOptions.end_options(~T[09:10:00], "24h", "17:00")

      assert List.last(options) == {"09:10 (+1)", "09:10+1"}
      assert {"09:15", "09:15"} in options
      assert {"09:00 (+1)", "09:00+1"} in options
    end

    test "keeps a stored end that is off the quarter-hour grid" do
      options = TimeOptions.end_options(~T[00:00:00], "24h", "23:59")

      assert {"23:59", "23:59"} in options
      assert length(options) == 97
    end
  end

  describe "window_options/2" do
    test "a same-day window offers what it always did" do
      day = %{start_time: ~T[09:00:00], end_time: ~T[10:00:00], ends_next_day: false}

      assert TimeOptions.window_options(day, "24h") ==
               TimeOptions.time_options_between(~T[09:00:00], ~T[10:00:00], "24h")
    end

    test "an overnight window runs through midnight in order, marking next-day times" do
      night = %{start_time: ~T[23:00:00], end_time: ~T[00:30:00], ends_next_day: true}

      assert TimeOptions.window_options(night, "24h") == [
               {"23:00", "23:00"},
               {"23:15", "23:15"},
               {"23:30", "23:30"},
               {"23:45", "23:45"},
               {"00:00 (+1)", "00:00"},
               {"00:15 (+1)", "00:15"},
               {"00:30 (+1)", "00:30"}
             ]
    end

    test "a 24-hour window ends on its own start time, the next day" do
      full = %{start_time: ~T[00:00:00], end_time: ~T[00:00:00], ends_next_day: true}
      options = TimeOptions.window_options(full, "24h")

      assert List.first(options) == {"00:00", "00:00"}
      assert List.last(options) == {"00:00 (+1)", "00:00"}
      assert length(options) == 97
    end
  end
end
