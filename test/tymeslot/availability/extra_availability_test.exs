defmodule Tymeslot.Availability.ExtraAvailabilityTest do
  @moduledoc """
  Extra available times: dates with a from and a to time, open besides a
  schedule's weekly hours.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :availability

  alias Tymeslot.Availability.{
    AvailabilityOverrideQueries,
    AvailabilityOverrideSchema,
    BusinessHours,
    ExtraAvailability,
    SlotGrid,
    WeeklySchedule
  }

  alias Tymeslot.Repo

  # 2030-04-06 is a Saturday, 2030-04-08 a Monday.
  @saturday ~D[2030-04-06]
  @monday ~D[2030-04-08]
  @today ~D[2030-04-01]

  setup do
    profile = insert(:profile, timezone: "Etc/UTC")
    schedule = insert(:availability_schedule, profile: profile, is_default: true)
    %{profile: profile, schedule: schedule}
  end

  describe "add/3" do
    test "adds several times on one date and lists them in order", %{schedule: schedule} do
      assert {:ok, _late} = add(schedule, @saturday, ~T[14:00:00], ~T[16:00:00])
      assert {:ok, _early} = add(schedule, @saturday, ~T[09:00:00], ~T[11:00:00])
      assert {:ok, _monday} = add(schedule, @monday, ~T[10:00:00], ~T[12:00:00])

      assert schedule.id
             |> ExtraAvailability.list_upcoming(@today)
             |> Enum.map(&{&1.date, &1.start_time}) == [
               {@saturday, ~T[09:00:00]},
               {@saturday, ~T[14:00:00]},
               {@monday, ~T[10:00:00]}
             ]
    end

    test "refuses a time overlapping another on the same date", %{schedule: schedule} do
      {:ok, _first} = add(schedule, @saturday, ~T[09:00:00], ~T[11:00:00])

      assert {:error, :overlap} = add(schedule, @saturday, ~T[10:30:00], ~T[12:00:00])
      assert {:ok, _touching} = add(schedule, @saturday, ~T[11:00:00], ~T[12:00:00])
    end

    test "refuses a past date and a backwards range", %{schedule: schedule} do
      assert {:error, :in_past} = add(schedule, ~D[2030-03-31], ~T[09:00:00], ~T[11:00:00])

      assert {:error, %Ecto.Changeset{}} =
               add(schedule, @saturday, ~T[11:00:00], ~T[09:00:00])
    end

    test "refuses more than a schedule can hold", %{schedule: schedule} do
      for n <- 1..ExtraAvailability.max_per_schedule() do
        insert(:availability_override,
          schedule: schedule,
          date: Date.add(@saturday, n),
          override_type: :extra_hours,
          start_time: ~T[09:00:00],
          end_time: ~T[10:00:00]
        )
      end

      assert {:error, :too_many} = add(schedule, @saturday, ~T[09:00:00], ~T[11:00:00])
    end

    test "leaves the other override types one per date", %{schedule: schedule} do
      {:ok, _extra} = add(schedule, @saturday, ~T[09:00:00], ~T[11:00:00])

      insert(:availability_override,
        schedule: schedule,
        date: @saturday,
        override_type: :unavailable
      )

      assert {:error, %Ecto.Changeset{}} =
               AvailabilityOverrideQueries.create_override(%{
                 schedule_id: schedule.id,
                 date: @saturday,
                 override_type: :unavailable
               })

      # The lookup for the day's replacement hours does not mistake an extra
      # time for one.
      assert %{override_type: :unavailable} =
               AvailabilityOverrideQueries.get_override_by_schedule_and_date(
                 schedule.id,
                 @saturday
               )
    end
  end

  describe "delete/2 and prune_past/1" do
    test "delete removes one time of the schedule only", %{schedule: schedule} do
      {:ok, extra} = add(schedule, @saturday, ~T[09:00:00], ~T[11:00:00])
      other = insert(:availability_schedule, profile: insert(:profile))

      assert {:error, :not_found} = ExtraAvailability.delete(other, extra.id)
      assert {:ok, _deleted} = ExtraAvailability.delete(schedule, extra.id)
      assert ExtraAvailability.list_upcoming(schedule.id, @today) == []
    end

    test "prune_past removes only extra times before the date", %{schedule: schedule} do
      past = insert_extra(schedule, ~D[2030-03-30])
      current = insert_extra(schedule, ~D[2030-03-31])

      replacement =
        insert(:availability_override,
          schedule: schedule,
          date: ~D[2030-03-29],
          override_type: :unavailable
        )

      assert {1, nil} = ExtraAvailability.prune_past(~D[2030-03-31])

      refute Repo.get(AvailabilityOverrideSchema, past.id)
      assert Repo.get(AvailabilityOverrideSchema, current.id)
      assert Repo.get(AvailabilityOverrideSchema, replacement.id)
    end
  end

  describe "the windows a date offers" do
    test "a schedule with every weekday off opens only its extra times", %{schedule: schedule} do
      {:ok, _morning} = add(schedule, @saturday, ~T[09:00:00], ~T[11:00:00])
      {:ok, _afternoon} = add(schedule, @saturday, ~T[14:00:00], ~T[15:00:00])

      assert [{~T[09:00:00], ~T[11:00:00]}, {~T[14:00:00], ~T[15:00:00]}] =
               open_times(schedule, @saturday)

      assert open_times(schedule, @monday) == []
      assert BusinessHours.business_day?(@saturday, schedule.id, %{owner_timezone: "Etc/UTC"})
      refute BusinessHours.business_day?(@monday, schedule.id, %{owner_timezone: "Etc/UTC"})
    end

    test "add to the weekly hours of an open day", %{schedule: schedule} do
      WeeklySchedule.upsert_day_availability(schedule.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[12:00:00]
      })

      {:ok, _evening} = add(schedule, @monday, ~T[18:00:00], ~T[20:00:00])

      assert open_times(schedule, @monday) == [
               {~T[09:00:00], ~T[12:00:00]},
               {~T[18:00:00], ~T[20:00:00]}
             ]
    end

    test "offer slots in each of them, and none in between", %{schedule: schedule} do
      {:ok, _morning} = add(schedule, @saturday, ~T[09:00:00], ~T[10:00:00])
      {:ok, _afternoon} = add(schedule, @saturday, ~T[14:00:00], ~T[15:00:00])

      config = %{schedule_id: schedule.id, slot_interval_minutes: 30}
      {:ok, starts} = SlotGrid.stream_for_date(@saturday, 30, "Etc/UTC", "Etc/UTC", config)

      assert Enum.map(starts, &DateTime.to_time/1) ==
               [~T[09:00:00], ~T[09:30:00], ~T[14:00:00], ~T[14:30:00]]
    end

    test "are closed by time off like any other hours", %{schedule: schedule, profile: profile} do
      {:ok, _extra} = add(schedule, @saturday, ~T[09:00:00], ~T[11:00:00])
      insert(:time_off_period, profile: profile, starts_on: @saturday, ends_on: @saturday)

      refute BusinessHours.business_day?(@saturday, schedule.id, %{owner_timezone: "Etc/UTC"})
    end

    test "are closed by an unavailable override on their date", %{schedule: schedule} do
      {:ok, _extra} = add(schedule, @saturday, ~T[09:00:00], ~T[11:00:00])

      insert(:availability_override,
        schedule: schedule,
        date: @saturday,
        override_type: :unavailable
      )

      assert open_times(schedule, @saturday) == []
      assert utc_times(schedule, @saturday) == []
      refute BusinessHours.business_day?(@saturday, schedule.id, %{owner_timezone: "Etc/UTC"})
    end
  end

  describe "an extra time over a weekly break" do
    setup %{schedule: schedule} do
      monday_hours =
        insert(:weekly_availability,
          schedule: schedule,
          day_of_week: 1,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )

      insert(:availability_break,
        weekly_availability: monday_hours,
        start_time: ~T[12:00:00],
        end_time: ~T[13:00:00]
      )

      :ok
    end

    test "opens the break on its date only", %{schedule: schedule} do
      {:ok, _lunch} = add(schedule, @monday, ~T[12:00:00], ~T[13:00:00])

      every_half_hour = for h <- 9..16, m <- [0, 30], do: Time.new!(h, m, 0)
      no_lunch = every_half_hour -- [~T[12:00:00], ~T[12:30:00]]

      assert utc_times(schedule, @monday) == every_half_hour
      assert utc_times(schedule, Date.add(@monday, 7)) == no_lunch
      assert utc_times(schedule, Date.add(@monday, -7)) == no_lunch
    end

    test "opens only the part of the break it covers", %{schedule: schedule} do
      {:ok, _half} = add(schedule, @monday, ~T[12:00:00], ~T[12:30:00])

      times = utc_times(schedule, @monday)

      assert ~T[12:00:00] in times
      refute ~T[12:30:00] in times
    end
  end

  describe "across timezones" do
    test "an owner ahead of UTC offers a booker behind it the times on their previous date",
         %{schedule: schedule} do
      # Saturday 09:00 to 10:00 in Tokyo is Friday 17:00 to 18:00 in Los Angeles.
      {:ok, _extra} = add(schedule, @saturday, ~T[09:00:00], ~T[10:00:00])

      assert starts(schedule, ~D[2030-04-05], "Asia/Tokyo", "America/Los_Angeles") ==
               [~U[2030-04-06 00:00:00Z], ~U[2030-04-06 00:30:00Z]]

      assert starts(schedule, @saturday, "Asia/Tokyo", "America/Los_Angeles") == []
    end

    test "an extra time on the owner's spring-forward date runs real hours",
         %{schedule: schedule} do
      # Warsaw skips 02:00 to 03:00 on 2030-03-31: 01:00 to 04:00 is two hours.
      dst_day = ~D[2030-03-31]

      {:ok, _extra} =
        ExtraAvailability.add(
          schedule,
          %{date: dst_day, start_time: ~T[01:00:00], end_time: ~T[04:00:00]},
          ~D[2030-03-01]
        )

      assert starts(schedule, dst_day, "Europe/Warsaw", "Europe/Warsaw") == [
               ~U[2030-03-31 00:00:00Z],
               ~U[2030-03-31 00:30:00Z],
               ~U[2030-03-31 01:00:00Z],
               ~U[2030-03-31 01:30:00Z]
             ]
    end
  end

  defp add(schedule, date, from, to),
    do: ExtraAvailability.add(schedule, %{date: date, start_time: from, end_time: to}, @today)

  defp insert_extra(schedule, date) do
    insert(:availability_override,
      schedule: schedule,
      date: date,
      override_type: :extra_hours,
      start_time: ~T[09:00:00],
      end_time: ~T[10:00:00]
    )
  end

  defp open_times(schedule, date) do
    [date]
    |> BusinessHours.owner_windows(schedule.id, "Etc/UTC", %{})
    |> Enum.map(&{DateTime.to_time(&1.start_dt), DateTime.to_time(&1.end_dt)})
  end

  defp utc_times(schedule, date) do
    schedule |> starts(date, "Etc/UTC", "Etc/UTC") |> Enum.map(&DateTime.to_time/1)
  end

  defp starts(schedule, date, owner_timezone, booker_timezone) do
    config = %{schedule_id: schedule.id, slot_interval_minutes: 30}

    {:ok, starts} =
      SlotGrid.starts_for_date(date, 30, owner_timezone, booker_timezone, config)

    Enum.map(starts, &DateTime.shift_zone!(&1, "Etc/UTC"))
  end
end
