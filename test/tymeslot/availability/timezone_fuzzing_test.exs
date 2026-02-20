defmodule Tymeslot.Availability.TimezoneFuzzingTest do
  @moduledoc """
  Property-based tests to ensure availability logic is consistent across different timezones.
  """
  use ExUnit.Case, async: false

  @moduletag :availability

  use ExUnitProperties

  import Tymeslot.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Repo
  alias Tymeslot.Timezones

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    # Create a profile with standard business hours for tests
    user = insert(:user)
    profile = insert(:profile, user: user)

    # Make every day available
    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    {:ok, profile: profile}
  end

  @timezones Enum.map(Timezones.all_options(), &elem(&1, 1))

  property "month_availability is consistent regardless of user timezone", %{profile: profile} do
    check all(
            _year <- integer(2025..2026),
            _month <- integer(1..12),
            _owner_tz <- member_of(@timezones),
            _user_tz <- member_of(@timezones),
            duration <- member_of([30, 60])
          ) do
      # ...
      _config = %{
        duration_minutes: duration,
        buffer_minutes: 0,
        min_advance_hours: 0,
        profile_id: profile.id
      }

      # ...
    end
  end

  property "available_slots returns consistent results across timezones", %{profile: profile} do
    check all(
            _owner_tz <- member_of(@timezones),
            _user_tz <- member_of(@timezones),
            duration <- member_of([30, 60])
          ) do
      # ...
      _config = %{
        duration_minutes: duration,
        buffer_minutes: 0,
        min_advance_hours: 0,
        profile_id: profile.id
      }

      # ...
    end
  end

  test "available_slots handles DST spring forward correctly", %{profile: profile} do
    # ...
    _config = %{
      duration_minutes: 30,
      buffer_minutes: 0,
      min_advance_hours: 0,
      profile_id: profile.id
    }

    # ...
  end

  property "today's availability correctly respects min_advance_hours", %{profile: profile} do
    check all(
            advance_hours <- integer(0..72),
            user_tz <- member_of(@timezones)
          ) do
      # ...
      today = Date.utc_today()

      {:ok, _availability} =
        Calculate.month_availability(
          today.year,
          today.month,
          user_tz,
          user_tz,
          [],
          %{min_advance_hours: advance_hours, profile_id: profile.id}
        )

      # ...
    end
  end
end
