defmodule Tymeslot.AvailabilityTestHelpers do
  @moduledoc """
  Helpers for availability-related tests to avoid repeated setup.
  """

  import Tymeslot.Factory
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.DatabaseSchemas.{ProfileSchema, UserSchema, WeeklyAvailabilitySchema}

  @default_day_attrs %{
    is_available: true,
    start_time: ~T[09:00:00],
    end_time: ~T[17:00:00]
  }

  @doc """
  Creates and returns a user/profile pair.
  """
  @spec create_profile(map()) :: %{user: UserSchema.t(), profile: ProfileSchema.t()}
  def create_profile(profile_attrs \\ %{}) do
    user = insert(:user)
    profile = insert(:profile, Map.put(profile_attrs, :user, user))
    %{user: user, profile: profile}
  end

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
    %{user: user, profile: profile} = create_profile()

    {:ok, day} =
      WeeklySchedule.create_day_availability(
        profile.id,
        day_of_week,
        Map.merge(@default_day_attrs, day_attrs)
      )

    %{user: user, profile: profile, day: day}
  end
end
