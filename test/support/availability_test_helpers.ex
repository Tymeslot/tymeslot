defmodule Tymeslot.AvailabilityTestHelpers do
  @moduledoc """
  Helpers for availability-related tests to avoid repeated setup.
  """

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Availability.WeeklyAvailabilitySchema
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.MeetingTestHelpers
  alias Tymeslot.Profiles.ProfileSchema

  @default_day_attrs %{
    is_available: true,
    start_time: ~T[09:00:00],
    end_time: ~T[17:00:00]
  }

  # Narrower window (11:00–17:00) used by the display/booking consistency tests;
  # deliberately away from the day boundary so timezone conversions never clip.
  @bookable_day_attrs %{
    is_available: true,
    start_time: ~T[11:00:00],
    end_time: ~T[17:00:00]
  }

  @doc """
  Creates a profile plus a day availability record with defaults unless overridden.
  """
  @spec create_profile_with_day(integer(), map()) ::
          %{
            user: UserSchema.t(),
            profile: ProfileSchema.t(),
            day: WeeklyAvailabilitySchema.t()
          }
  def create_profile_with_day(day_of_week \\ 1, day_attrs \\ %{}) do
    %{user: user, profile: profile} = MeetingTestHelpers.create_user_with_profile()

    {:ok, day} =
      WeeklySchedule.create_day_availability(
        profile.id,
        day_of_week,
        Map.merge(@default_day_attrs, day_attrs)
      )

    %{user: user, profile: profile, day: day}
  end

  @doc """
  Creates a user + profile with a weekday schedule guaranteed to surface slots,
  and returns the user, profile and profile_id.

  ## Options
    * `:timezone` - profile timezone (default `"Etc/UTC"`)
    * `:days`     - ISO weekdays made available (default `1..5`)
    * `:hours`    - `%{is_available:, start_time:, end_time:}` per day
      (default 11:00–17:00)
  """
  @spec create_bookable_profile(keyword()) :: %{
          user: UserSchema.t(),
          profile: ProfileSchema.t(),
          profile_id: integer()
        }
  def create_bookable_profile(opts \\ []) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    days = Keyword.get(opts, :days, Enum.to_list(1..5))
    hours = Keyword.get(opts, :hours, @bookable_day_attrs)

    %{user: user, profile: profile} =
      MeetingTestHelpers.create_user_with_profile(%{timezone: timezone})

    for day_of_week <- days do
      {:ok, _day} = WeeklySchedule.create_day_availability(profile.id, day_of_week, hours)
    end

    %{user: user, profile: profile, profile_id: profile.id}
  end

  @doc """
  Returns a weekday at least `offset` days from today, skipping weekends. Far
  enough out that `min_advance_hours` / `max_advance_booking_days` never clip the
  offered slots.
  """
  @spec next_bookable_weekday(non_neg_integer()) :: Date.t()
  def next_bookable_weekday(offset \\ 10) do
    date = Date.add(Date.utc_today(), offset)

    case Date.day_of_week(date) do
      6 -> Date.add(date, 2)
      7 -> Date.add(date, 1)
      _weekday -> date
    end
  end
end
