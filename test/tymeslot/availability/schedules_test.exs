defmodule Tymeslot.Availability.SchedulesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability

  import Tymeslot.Factory

  alias Tymeslot.Availability.AvailabilityOverrideQueries
  alias Tymeslot.Availability.AvailabilityScheduleQueries
  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklyAvailabilityQueries
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user)

    {:ok, user: user, profile: profile}
  end

  describe "create_default/2" do
    test "creates a default schedule with seven weekday rows", %{profile: profile} do
      {:ok, schedule} = Schedules.create_default(profile.id)

      assert schedule.is_default
      assert schedule.name == "Working hours"
      assert length(WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks(schedule.id)) == 7
    end
  end

  describe "create/2" do
    test "seeds seven weekday rows on a new schedule", %{profile: profile} do
      {:ok, _default} = Schedules.create_default(profile.id)
      {:ok, schedule} = Schedules.create(profile.id, %{name: "Evenings"})

      days = WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks(schedule.id)

      refute schedule.is_default
      assert length(days) == 7
      assert Enum.count(days, & &1.is_available) == 5
    end

    test "rejects a duplicate name within the same profile", %{profile: profile} do
      {:ok, _default} = Schedules.create_default(profile.id)
      {:ok, _first} = Schedules.create(profile.id, %{name: "Evenings"})

      assert {:error, changeset} = Schedules.create(profile.id, %{name: "Evenings"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "accepts string-keyed params from the form", %{profile: profile} do
      {:ok, _default} = Schedules.create_default(profile.id)

      assert {:ok, schedule} = Schedules.create(profile.id, %{"name" => "Evenings"})
      assert schedule.name == "Evenings"
    end
  end

  describe "get_default/1" do
    test "returns the profile's default schedule", %{profile: profile} do
      {:ok, default} = Schedules.create_default(profile.id)
      {:ok, _other} = Schedules.create(profile.id, %{name: "Evenings"})

      assert Schedules.get_default(profile.id).id == default.id
    end
  end

  describe "set_default/1" do
    test "moves the default flag and leaves exactly one default", %{profile: profile} do
      {:ok, original} = Schedules.create_default(profile.id)
      {:ok, evenings} = Schedules.create(profile.id, %{name: "Evenings"})

      {:ok, _updated} = Schedules.set_default(evenings)

      assert Schedules.get_default(profile.id).id == evenings.id
      refute AvailabilityScheduleQueries.get(original.id).is_default
      assert Enum.count(Schedules.list_for_profile(profile.id), & &1.is_default) == 1
    end

    test "is a no-op on a schedule that is already the default", %{profile: profile} do
      {:ok, default} = Schedules.create_default(profile.id)

      assert {:ok, unchanged} = Schedules.set_default(default)
      assert unchanged.id == default.id
      assert Enum.count(Schedules.list_for_profile(profile.id), & &1.is_default) == 1
    end
  end

  describe "delete/1" do
    test "refuses to delete the default schedule", %{profile: profile} do
      {:ok, default} = Schedules.create_default(profile.id)

      assert {:error, :cannot_delete_default} = Schedules.delete(default)
      assert AvailabilityScheduleQueries.get(default.id)
    end

    test "reverts meeting types to the default", %{user: user, profile: profile} do
      {:ok, _default} = Schedules.create_default(profile.id)
      {:ok, evenings} = Schedules.create(profile.id, %{name: "Evenings"})

      meeting_type = insert(:meeting_type, user: user, availability_schedule_id: evenings.id)

      {:ok, _deleted} = Schedules.delete(evenings)

      reloaded = MeetingTypes.get_meeting_type(meeting_type.id, user.id)

      assert reloaded.availability_schedule_id == nil
    end

    test "cascades its weekly rows", %{profile: profile} do
      {:ok, _default} = Schedules.create_default(profile.id)
      {:ok, evenings} = Schedules.create(profile.id, %{name: "Evenings"})

      {:ok, _deleted} = Schedules.delete(evenings)

      assert WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks(evenings.id) == []
    end
  end

  describe "duplicate/1 copying" do
    test "copies the weekly pattern and policy but not the date overrides", %{profile: profile} do
      {:ok, source} = Schedules.create_default(profile.id)
      {:ok, source} = Schedules.update_policy(source, %{buffer_minutes: 45})

      {:ok, _override} =
        AvailabilityOverrideQueries.create_override(%{
          schedule_id: source.id,
          date: ~D[2026-12-24],
          override_type: "unavailable",
          reason: "Holiday"
        })

      {:ok, copy} = Schedules.duplicate(source)

      source_days = WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks(source.id)
      copy_days = WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks(copy.id)

      refute copy.is_default
      assert length(copy_days) == 7
      assert Enum.map(copy_days, & &1.is_available) == Enum.map(source_days, & &1.is_available)
      assert copy.buffer_minutes == 45

      assert AvailabilityOverrideQueries.get_overrides_by_schedule_and_date_range(
               copy.id,
               ~D[2026-12-01],
               ~D[2026-12-31]
             ) == []
    end
  end

  describe "duplicate/1" do
    test "names the copy after its source", %{profile: profile} do
      {:ok, source} = Schedules.create_default(profile.id)

      assert {:ok, %{name: "Working hours (copy)"}} = Schedules.duplicate(source)
    end

    test "numbers each further copy of the same source", %{profile: profile} do
      {:ok, source} = Schedules.create_default(profile.id)

      {:ok, first} = Schedules.duplicate(source)
      {:ok, second} = Schedules.duplicate(source)
      {:ok, third} = Schedules.duplicate(source)

      assert [first.name, second.name, third.name] ==
               ["Working hours (copy)", "Working hours (copy) 2", "Working hours (copy) 3"]
    end

    test "shortens a source name at the length limit so every copy stays distinct and valid",
         %{profile: profile} do
      max = AvailabilityScheduleSchema.name_max_length()
      {:ok, source} = Schedules.create(profile.id, %{name: String.duplicate("a", max)})

      task =
        Task.async(fn ->
          for _copy <- 1..(Schedules.max_schedules() - 1), do: Schedules.duplicate(source)
        end)

      results = Task.await(task, 5_000)
      names = Enum.map(results, fn {:ok, copy} -> copy.name end)

      assert names == [
               String.duplicate("a", max - 7) <> " (copy)",
               String.duplicate("a", max - 9) <> " (copy) 2",
               String.duplicate("a", max - 9) <> " (copy) 3",
               String.duplicate("a", max - 9) <> " (copy) 4"
             ]

      assert Enum.all?(names, &(String.length(&1) <= max))
    end
  end

  describe "resolve_for_meeting_type/1" do
    test "returns the meeting type's own schedule when set", %{user: user, profile: profile} do
      {:ok, _default} = Schedules.create_default(profile.id)
      {:ok, evenings} = Schedules.create(profile.id, %{name: "Evenings"})
      meeting_type = insert(:meeting_type, user: user, availability_schedule_id: evenings.id)

      assert Schedules.resolve_for_meeting_type(meeting_type).id == evenings.id
    end

    test "falls back to the profile default when unset", %{user: user, profile: profile} do
      {:ok, default} = Schedules.create_default(profile.id)
      meeting_type = insert(:meeting_type, user: user, availability_schedule_id: nil)

      assert Schedules.resolve_for_meeting_type(meeting_type).id == default.id
    end

    test "returns nil for a nil meeting type" do
      assert Schedules.resolve_for_meeting_type(nil) == nil
    end
  end

  describe "resolve_for/2" do
    test "prefers the meeting type's schedule over the profile default", %{
      user: user,
      profile: profile
    } do
      {:ok, _default} = Schedules.create_default(profile.id)
      {:ok, evenings} = Schedules.create(profile.id, %{name: "Evenings"})
      meeting_type = insert(:meeting_type, user: user, availability_schedule_id: evenings.id)

      assert Schedules.resolve_for(meeting_type, profile).id == evenings.id
    end

    test "uses the profile default when the meeting type has none", %{profile: profile} do
      {:ok, default} = Schedules.create_default(profile.id)

      assert Schedules.resolve_for(nil, profile).id == default.id
    end

    test "returns nil without a profile" do
      assert Schedules.resolve_for(nil, nil) == nil
    end
  end

  describe "update_policy/2" do
    test "updates the three policy fields from string params", %{profile: profile} do
      {:ok, schedule} = Schedules.create_default(profile.id)

      {:ok, updated} =
        Schedules.update_policy(schedule, %{
          "buffer_minutes" => "30",
          "min_advance_hours" => "48",
          "advance_booking_days" => "60"
        })

      assert updated.buffer_minutes == 30
      assert updated.min_advance_hours == 48
      assert updated.advance_booking_days == 60
    end

    test "rejects an out-of-range value", %{profile: profile} do
      {:ok, schedule} = Schedules.create_default(profile.id)

      assert {:error, changeset} = Schedules.update_policy(schedule, %{"buffer_minutes" => "999"})
      assert Map.has_key?(errors_on(changeset), :buffer_minutes)
    end
  end

  describe "cache invalidation" do
    # Every mutation here changes what the slot engine would compute, and the
    # availability cache is keyed by user, so a surviving entry would keep
    # offering the old hours to whoever is on the booking page.
    test "update_policy clears the user's cached availability", %{
      user: user,
      profile: profile
    } do
      {:ok, schedule} = Schedules.create_default(profile.id)
      key = seed_cache(user.id)

      {:ok, _updated} = Schedules.update_policy(schedule, %{"buffer_minutes" => "45"})

      assert cache_missing?(key)
    end

    test "set_default clears it, because every unpinned meeting type just moved", %{
      user: user,
      profile: profile
    } do
      {:ok, _default} = Schedules.create_default(profile.id)
      {:ok, other} = Schedules.create(profile.id, %{name: "Evenings"})
      key = seed_cache(user.id)

      {:ok, _promoted} = Schedules.set_default(other)

      assert cache_missing?(key)
    end

    test "delete clears it, because its meeting types fall back to the default", %{
      user: user,
      profile: profile
    } do
      {:ok, _default} = Schedules.create_default(profile.id)
      {:ok, other} = Schedules.create(profile.id, %{name: "Evenings"})
      key = seed_cache(user.id)

      {:ok, _deleted} = Schedules.delete(other)

      assert cache_missing?(key)
    end

    test "a rejected write leaves the cache alone", %{user: user, profile: profile} do
      {:ok, schedule} = Schedules.create_default(profile.id)
      key = seed_cache(user.id)

      assert {:error, _changeset} =
               Schedules.update_policy(schedule, %{"buffer_minutes" => "999"})

      refute cache_missing?(key)
    end

    defp seed_cache(user_id) do
      key =
        AvailabilityCache.availability_range_key(
          user_id,
          ~D[2026-09-01],
          ~D[2026-09-30],
          "Europe/Berlin",
          30,
          nil
        )

      AvailabilityCache.put(key, :cached)
      refute cache_missing?(key)

      key
    end

    defp cache_missing?(key) do
      AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed
    end
  end

  describe "meeting_type_names/1" do
    test "names the meeting types that would fall back on delete", %{
      user: user,
      profile: profile
    } do
      {:ok, _default} = Schedules.create_default(profile.id)
      {:ok, evenings} = Schedules.create(profile.id, %{name: "Evenings"})

      insert(:meeting_type, user: user, name: "Deep work", availability_schedule_id: evenings.id)
      insert(:meeting_type, user: user, name: "Intro call", availability_schedule_id: nil)

      assert Schedules.meeting_type_names(evenings.id) == ["Deep work"]
    end
  end
end
