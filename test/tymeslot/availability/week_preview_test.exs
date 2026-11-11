defmodule Tymeslot.Availability.WeekPreviewTest do
  @moduledoc """
  `Tymeslot.Availability.week_preview/2`: the host's next seven days, slots and
  busy blocks, in the host's timezone.

  The clock is frozen on the Sunday before a Monday at least two weeks out, so
  minimum notice never eats into the week and the test does not depend on when
  it runs.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability
  alias Tymeslot.Availability.ExtraAvailability
  alias Tymeslot.Availability.WeekPreview
  alias Tymeslot.CalendarMock
  alias Tymeslot.Mocks.Calendar, as: CalendarFixtures
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()

    monday =
      Date.utc_today() |> Date.add(14) |> Date.beginning_of_week(:monday) |> Date.add(7)

    ClockHelpers.freeze_clock(DateTime.new!(Date.add(monday, -1), ~T[00:00:00], "Etc/UTC"))
    %{monday: monday}
  end

  @office_hours %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}

  defp host(opts \\ []), do: opts |> host_with_schedule() |> Map.fetch!(:profile)

  defp host_with_schedule(opts \\ []),
    do: create_bookable_profile(Keyword.put_new(opts, :hours, @office_hours))

  defp event_at(date, from, to, opts \\ []) do
    zone = Keyword.get(opts, :zone, "Etc/UTC")

    CalendarFixtures.event(
      start_time: DateTime.new!(date, from, zone),
      end_time: DateTime.new!(Keyword.get(opts, :end_date, date), to, zone)
    )
  end

  defp stub_events(events) do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to -> {:ok, events} end)
  end

  test "counts free slots across the next seven days", %{monday: monday} do
    assert {:ok, %WeekPreview{} = preview} = Availability.week_preview(host(), today: monday)

    assert Enum.map(preview.days, & &1.date) == Enum.map(0..6, &Date.add(monday, &1))
    assert hd(hd(preview.days).slots) == "09:00"

    weekday_slots = preview.days |> Enum.take(5) |> Enum.map(&length(&1.slots))
    assert Enum.all?(weekday_slots, &(&1 == hd(weekday_slots)))
    assert hd(weekday_slots) > 0
    assert preview.days |> Enum.drop(5) |> Enum.all?(&(&1.slots == [] and &1.busy == []))
    assert preview.slot_count == 5 * hd(weekday_slots)
    assert preview.first_busy == nil
  end

  test "a busy event removes its slots and appears as a busy block", %{monday: monday} do
    tuesday = Date.add(monday, 1)

    stub_events([
      CalendarFixtures.event(
        start_time: DateTime.new!(tuesday, ~T[14:00:00], "Etc/UTC"),
        end_time: DateTime.new!(tuesday, ~T[15:00:00], "Etc/UTC")
      )
    ])

    assert {:ok, preview} = Availability.week_preview(host(), today: monday)

    [_monday, tuesday_preview | _rest] = preview.days
    refute "14:00" in tuesday_preview.slots
    refute "14:30" in tuesday_preview.slots
    assert "13:00" in tuesday_preview.slots
    assert tuesday_preview.busy == [{~T[14:00:00], ~T[15:00:00]}]
    assert preview.first_busy == %{date: tuesday, start: ~T[14:00:00]}
  end

  test "a busy block is clipped to the host's open hours", %{monday: monday} do
    stub_events([
      CalendarFixtures.event(
        start_time: DateTime.new!(monday, ~T[07:00:00], "Etc/UTC"),
        end_time: DateTime.new!(monday, ~T[10:00:00], "Etc/UTC")
      )
    ])

    assert {:ok, %{days: [first | _rest]}} = Availability.week_preview(host(), today: monday)
    assert first.busy == [{~T[09:00:00], ~T[10:00:00]}]
  end

  test "a calendar error returns calendar_unavailable", %{monday: monday} do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      {:error, :timeout}
    end)

    assert {:error, :calendar_unavailable} = Availability.week_preview(host(), today: monday)
  end

  test "days are in the host's timezone" do
    # 23:00 UTC on a Sunday is already Monday noon in Auckland.
    sunday = Date.utc_today() |> Date.add(14) |> Date.beginning_of_week(:monday) |> Date.add(6)
    ClockHelpers.freeze_clock(DateTime.new!(sunday, ~T[23:00:00], "Etc/UTC"))

    profile = host(timezone: "Pacific/Auckland")

    assert {:ok, %{days: days}} = Availability.week_preview(profile)
    assert hd(days).date == Date.add(sunday, 1)
    assert length(days) == 7
  end

  test "the calendar is fetched once per call", %{monday: monday} do
    expect(CalendarMock, :get_events_for_range_fresh, 1, fn _user_id, _from, _to -> {:ok, []} end)

    assert {:ok, _preview} = Availability.week_preview(host(), today: monday)
  end

  describe "busy blocks" do
    test "overlapping events are merged into one block", %{monday: monday} do
      tuesday = Date.add(monday, 1)

      stub_events([
        event_at(tuesday, ~T[14:00:00], ~T[15:00:00]),
        event_at(tuesday, ~T[14:30:00], ~T[16:00:00])
      ])

      assert {:ok, %{days: [_monday, day | _rest]}} =
               Availability.week_preview(host(), today: monday)

      assert day.busy == [{~T[14:00:00], ~T[16:00:00]}]
    end

    test "an event crossing midnight shows on both days, clipped to the open hours",
         %{monday: monday} do
      tuesday = Date.add(monday, 1)
      stub_events([event_at(monday, ~T[16:00:00], ~T[10:00:00], end_date: tuesday)])

      assert {:ok, %{days: [first, second | _rest]}} =
               Availability.week_preview(host(), today: monday)

      assert first.busy == [{~T[16:00:00], ~T[17:00:00]}]
      assert second.busy == [{~T[09:00:00], ~T[10:00:00]}]
    end

    test "an overnight window on a night the clocks go back at midnight still draws its block" do
      # In Santiago 23:59:59 on Saturday 3 April 2027 happens twice.
      saturday = ~D[2027-04-03]
      ClockHelpers.freeze_clock(~U[2027-04-01 00:00:00Z])
      zone = "America/Santiago"

      profile =
        host(
          timezone: zone,
          days: [6],
          hours: %{
            is_available: true,
            start_time: ~T[20:00:00],
            end_time: ~T[02:00:00],
            ends_next_day: true
          }
        )

      stub_events([event_at(saturday, ~T[21:00:00], ~T[22:00:00], zone: zone)])

      assert {:ok, %{days: [first | _rest]}} = Availability.week_preview(profile, today: saturday)
      assert first.date == saturday
      assert first.busy == [{~T[21:00:00], ~T[22:00:00]}]
    end

    test "an all-day event blocks the whole open day", %{monday: monday} do
      tuesday = Date.add(monday, 1)

      stub_events([
        %{
          start_time: tuesday,
          end_time: Date.add(tuesday, 1),
          all_day: true,
          uid: "all-day-1",
          summary: "Away"
        }
      ])

      assert {:ok, %{days: [_monday, day | _rest]}} =
               Availability.week_preview(host(), today: monday)

      assert day.slots == []
      assert day.busy == [{~T[09:00:00], ~T[17:00:00]}]
    end

    test "a day closed by an override shows no busy block", %{monday: monday} do
      %{profile: profile, schedule: schedule} = host_with_schedule()
      tuesday = Date.add(monday, 1)

      insert(:availability_override,
        schedule: schedule,
        date: tuesday,
        override_type: :unavailable
      )

      stub_events([event_at(tuesday, ~T[14:00:00], ~T[15:00:00])])

      assert {:ok, %{days: [_monday, day | _rest], first_busy: nil}} =
               Availability.week_preview(profile, today: monday)

      assert day.busy == []
      assert day.slots == []
    end

    test "an extra window shows its busy block on an otherwise closed day", %{monday: monday} do
      %{profile: profile, schedule: schedule} = host_with_schedule()
      saturday = Date.add(monday, 5)

      {:ok, _extra} =
        ExtraAvailability.add(
          schedule,
          %{date: saturday, start_time: ~T[10:00:00], end_time: ~T[12:00:00]},
          Date.utc_today()
        )

      stub_events([event_at(saturday, ~T[11:00:00], ~T[14:00:00])])

      assert {:ok, %{days: days}} = Availability.week_preview(profile, today: monday)
      day = Enum.at(days, 5)

      assert day.busy == [{~T[11:00:00], ~T[12:00:00]}]
      assert "10:00" in day.slots
    end

    test "first_busy is the earliest block that has not ended, one under way included",
         %{monday: monday} do
      tuesday = Date.add(monday, 1)

      stub_events([
        event_at(monday, ~T[10:00:00], ~T[11:00:00]),
        event_at(tuesday, ~T[14:00:00], ~T[15:00:00]),
        event_at(tuesday, ~T[16:00:00], ~T[16:30:00])
      ])

      ClockHelpers.freeze_clock(DateTime.new!(tuesday, ~T[14:30:00], "Etc/UTC"))

      assert {:ok, %{first_busy: first_busy}} = Availability.week_preview(host(), today: monday)
      assert first_busy == %{date: tuesday, start: ~T[14:00:00]}
    end
  end

  describe "time off" do
    test "a day the host is away has no busy blocks and no slots", %{monday: monday} do
      tuesday = Date.add(monday, 1)
      profile = host()
      insert(:time_off_period, profile: profile, starts_on: tuesday, ends_on: tuesday)
      stub_events([event_at(tuesday, ~T[10:00:00], ~T[11:00:00])])

      assert {:ok, %{days: [first, away | _rest], first_busy: nil}} =
               Availability.week_preview(profile, today: monday)

      assert away.date == tuesday
      assert away.busy == []
      assert away.slots == []
      assert first.slots != []
    end

    test "first_busy passes over a day the host is away", %{monday: monday} do
      tuesday = Date.add(monday, 1)
      thursday = Date.add(monday, 3)
      profile = host()
      insert(:time_off_period, profile: profile, starts_on: tuesday, ends_on: tuesday)

      stub_events([
        event_at(tuesday, ~T[10:00:00], ~T[11:00:00]),
        event_at(thursday, ~T[14:00:00], ~T[15:00:00])
      ])

      assert {:ok, %{first_busy: first_busy}} = Availability.week_preview(profile, today: monday)
      assert first_busy == %{date: thursday, start: ~T[14:00:00]}
    end

    test "a part-day period clips a block to the hours that remain", %{monday: monday} do
      profile = host()

      insert(:time_off_period,
        profile: profile,
        starts_on: monday,
        ends_on: monday,
        start_time: ~T[09:00:00],
        end_time: ~T[12:00:00]
      )

      stub_events([event_at(monday, ~T[11:00:00], ~T[14:00:00])])

      assert {:ok, %{days: [first | _rest], first_busy: first_busy}} =
               Availability.week_preview(profile, today: monday)

      assert first.busy == [{~T[12:00:00], ~T[14:00:00]}]
      assert first_busy == %{date: monday, start: ~T[12:00:00]}
      refute "10:00" in first.slots
      assert "15:00" in first.slots
    end

    test "a period in the middle of the day leaves a block on either side", %{monday: monday} do
      profile = host()

      insert(:time_off_period,
        profile: profile,
        starts_on: monday,
        ends_on: monday,
        start_time: ~T[12:00:00],
        end_time: ~T[14:00:00]
      )

      stub_events([event_at(monday, ~T[10:00:00], ~T[16:00:00])])

      assert {:ok, %{days: [first | _rest]}} = Availability.week_preview(profile, today: monday)
      assert first.busy == [{~T[10:00:00], ~T[12:00:00]}, {~T[14:00:00], ~T[16:00:00]}]
    end
  end

  describe "time off in awkward weeks" do
    test "a period over several days empties each of them and no others", %{monday: monday} do
      profile = host()

      insert(:time_off_period,
        profile: profile,
        starts_on: Date.add(monday, 1),
        ends_on: Date.add(monday, 3)
      )

      stub_events(
        for day <- [monday, Date.add(monday, 2), Date.add(monday, 4)],
            do: event_at(day, ~T[10:00:00], ~T[11:00:00])
      )

      assert {:ok, %{days: days, first_busy: first_busy}} =
               Availability.week_preview(profile, today: monday)

      [mon, tue, wed, thu, fri | _weekend] = days

      for away <- [tue, wed, thu] do
        assert {away.slots, away.busy} == {[], []}
      end

      assert mon.busy == [{~T[10:00:00], ~T[11:00:00]}]
      assert fri.busy == [{~T[10:00:00], ~T[11:00:00]}]
      refute "10:00" in mon.slots
      assert "09:00" in fri.slots
      assert first_busy == %{date: monday, start: ~T[10:00:00]}
    end

    # The clocks change at 01:00 on the last Sunday of March and of October
    # (the day is 23 or 25 hours long), which must not shift the hours a
    # part-day period takes out, nor stretch an all-day one into its neighbours.
    for {label, monday_iso} <- [{"March", "2027-03-22"}, {"October", "2027-10-25"}] do
      @monday Date.from_iso8601!(monday_iso)

      test "a part-day period on the Europe/London #{label} clock change takes out its own hours" do
        monday = @monday
        sunday = Date.add(monday, 6)
        ClockHelpers.freeze_clock(DateTime.new!(Date.add(monday, -1), ~T[00:00:00], "Etc/UTC"))
        zone = "Europe/London"
        profile = host(timezone: zone, days: Enum.to_list(1..7))

        insert(:time_off_period,
          profile: profile,
          starts_on: sunday,
          ends_on: sunday,
          start_time: ~T[09:00:00],
          end_time: ~T[12:00:00]
        )

        stub_events([event_at(sunday, ~T[11:00:00], ~T[14:00:00], zone: zone)])

        assert {:ok, %{days: days}} = Availability.week_preview(profile, today: monday)
        change_day = List.last(days)

        assert change_day.date == sunday
        assert change_day.busy == [{~T[12:00:00], ~T[14:00:00]}]
        refute "10:00" in change_day.slots
        assert "15:00" in change_day.slots
      end

      test "an all-day period across the Europe/London #{label} clock change spares the days around it" do
        monday = @monday
        saturday = Date.add(monday, 5)
        ClockHelpers.freeze_clock(DateTime.new!(Date.add(monday, -1), ~T[00:00:00], "Etc/UTC"))
        zone = "Europe/London"
        profile = host(timezone: zone, days: Enum.to_list(1..7))

        insert(:time_off_period,
          profile: profile,
          starts_on: saturday,
          ends_on: Date.add(saturday, 2)
        )

        stub_events(
          for day <- [Date.add(monday, 4), saturday, Date.add(saturday, 1)],
              do: event_at(day, ~T[10:00:00], ~T[11:00:00], zone: zone)
        )

        assert {:ok, %{days: [mon, _tue, _wed, _thu, fri, sat, sun]}} =
                 Availability.week_preview(profile, today: monday)

        for away <- [sat, sun], do: assert({away.slots, away.busy} == {[], []})
        assert fri.busy == [{~T[10:00:00], ~T[11:00:00]}]
        assert "09:00" in mon.slots
      end
    end

    # Saturday 20:00 to 02:00 on Sunday, owner in UTC.
    @night %{
      is_available: true,
      start_time: ~T[20:00:00],
      end_time: ~T[02:00:00],
      ends_next_day: true
    }

    test "an all-day period on the morning an overnight window runs into removes its tail",
         %{monday: monday} do
      saturday = Date.add(monday, 5)
      sunday = Date.add(monday, 6)
      profile = host(days: [6], hours: @night)
      insert(:time_off_period, profile: profile, starts_on: sunday, ends_on: sunday)
      stub_events([event_at(saturday, ~T[21:00:00], ~T[22:00:00])])

      assert {:ok, %{days: days}} = Availability.week_preview(profile, today: monday)
      [sat, sun] = Enum.take(days, -2)

      assert "20:00" in sat.slots
      assert sat.busy == [{~T[21:00:00], ~T[22:00:00]}]
      assert {sun.slots, sun.busy} == {[], []}
    end

    test "an all-day period on the night an overnight window opens takes its evening",
         %{monday: monday} do
      saturday = Date.add(monday, 5)
      profile = host(days: [6], hours: @night)
      insert(:time_off_period, profile: profile, starts_on: saturday, ends_on: saturday)
      stub_events([event_at(saturday, ~T[21:00:00], ~T[22:00:00])])

      assert {:ok, %{days: days}} = Availability.week_preview(profile, today: monday)
      sat = Enum.at(days, 5)

      assert {sat.slots, sat.busy} == {[], []}
    end
  end

  test "busy blocks are in the host's timezone", %{monday: monday} do
    # 12:30 UTC on Sunday is just after midnight on Monday in Auckland, in or out of DST.
    ClockHelpers.freeze_clock(DateTime.new!(Date.add(monday, -1), ~T[12:30:00], "Etc/UTC"))
    stub_events([event_at(monday, ~T[10:00:00], ~T[11:00:00], zone: "Pacific/Auckland")])

    assert {:ok, %{days: [first | _rest], first_busy: first_busy}} =
             Availability.week_preview(host(timezone: "Pacific/Auckland"))

    assert first.date == monday
    assert first.busy == [{~T[10:00:00], ~T[11:00:00]}]
    assert hd(first.slots) == "09:00"
    assert first_busy == %{date: monday, start: ~T[10:00:00]}
  end

  test "a timezone that is not a real zone falls back to the default zone", %{monday: monday} do
    profile = %{host() | timezone: "Mars/Olympus_Mons"}

    assert {:ok, %{days: days}} = Availability.week_preview(profile, today: monday)
    assert length(days) == 7
  end
end
