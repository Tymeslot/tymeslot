defmodule TymeslotWeb.Live.Scheduling.CalendarDaysDemoTest do
  # The demo provider is application config, so these cannot run alongside
  # tests that read the default one.
  use Tymeslot.DataCase, async: false

  @moduletag :scheduling

  import Tymeslot.ConfigTestHelpers

  alias TymeslotWeb.Live.Scheduling.CalendarDays

  # Answers for a profile marked `demo: true` with a predicate offering
  # Wednesdays only, and for any other profile with `nil`.
  defmodule WednesdayDemoProvider do
    @spec day_available_fn(map(), String.t()) :: (Date.t() -> boolean()) | nil
    def day_available_fn(%{demo: true}, _user_timezone),
      do: fn date -> Date.day_of_week(date) == 3 end

    def day_available_fn(_profile, _user_timezone), do: nil
  end

  @demo_profile %{id: -1, demo: true}

  setup do
    with_config(:tymeslot, demo_provider: WednesdayDemoProvider)
  end

  describe "the month grid of a demo profile" do
    test "offers exactly the days the provider's predicate does" do
      days = CalendarDays.get_calendar_days("Etc/UTC", 2027, 4, :monday, @demo_profile, nil)

      assert days != []

      assert Enum.reject(days, fn day ->
               day.available == (day.date |> Date.from_iso8601!() |> Date.day_of_week() == 3)
             end) == []
    end

    test "closes past days whatever the predicate says" do
      days = CalendarDays.get_calendar_days("Etc/UTC", 2020, 1, :monday, @demo_profile, nil)

      assert Enum.any?(days, &(Date.day_of_week(Date.from_iso8601!(&1.date)) == 3))
      refute Enum.any?(days, & &1.available)
    end

    test "a loaded availability map takes precedence over the predicate" do
      map = %{"2027-04-05" => true, "2027-04-07" => false}

      days =
        "Etc/UTC"
        |> CalendarDays.get_calendar_days(2027, 4, :monday, @demo_profile, map)
        |> Map.new(&{&1.date, &1.available})

      # Monday the 5th is open and Wednesday the 7th closed, against the predicate.
      assert days["2027-04-05"] == true
      assert days["2027-04-07"] == false
    end
  end

  describe "the week strip of a demo profile" do
    test "agrees with the predicate across a month boundary" do
      # Monday 29 March to Sunday 4 April 2027; the Wednesday is the 31st.
      days = CalendarDays.get_week_days(~D[2027-03-29], @demo_profile, nil, "Etc/UTC")

      assert Enum.map(days, & &1.available) == [false, false, true, false, false, false, false]
    end

    test "closes past days whatever the predicate says" do
      days = CalendarDays.get_week_days(~D[2020-01-06], @demo_profile, nil, "Etc/UTC")

      assert length(days) == 7
      refute Enum.any?(days, & &1.available)
    end
  end
end
