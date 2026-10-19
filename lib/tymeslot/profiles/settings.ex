defmodule Tymeslot.Profiles.Settings do
  @moduledoc """
  Subcomponent for profile settings updates during onboarding and beyond.
  This module coordinates updates across multiple profile aspects.
  """

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema

  @policy_param_keys ~w(buffer_before_minutes buffer_after_minutes advance_booking_days min_advance_hours)

  @type profile :: ProfileSchema.t()

  @typedoc ~S'String-keyed params from the basic-settings form (expects "full_name", "username", "timezone").'
  @type basic_settings_params :: %{
          optional(String.t()) => term()
        }

  @typedoc ~S'String-keyed params from the scheduling-preferences form (expects "buffer_before_minutes", "buffer_after_minutes", "advance_booking_days", "min_advance_hours").'
  @type scheduling_params :: %{
          optional(String.t()) => term()
        }

  @doc """
  Updates basic profile settings (name, username, timezone), as the
  onboarding form submits them.

  The username goes through `Profiles.change_username/2`, so it is validated,
  rate limited when it actually changes, and can publish the booking page,
  exactly as it would from the profile settings page.
  """
  @spec update_basic_settings(ProfileSchema.t(), %{String.t() => term()}) ::
          {:ok, ProfileSchema.t()} | {:error, term()}
  def update_basic_settings(profile, params) do
    full_name = Map.get(params, "full_name", profile.full_name || "")
    username = Map.get(params, "username", profile.username || "")
    timezone = Map.get(params, "timezone", Profiles.timezone(profile))

    details = %{full_name: full_name, timezone: timezone}

    # The name and time zone are checked before the username is written, so
    # a refused name does not spend a username change.
    with :ok <- valid_details(profile, details),
         {:ok, profile} <- Profiles.change_username(profile, username) do
      Profiles.update_basic_details(profile, details)
    end
  end

  defp valid_details(profile, details) do
    case ProfileSchema.basic_changeset(profile, details) do
      %{valid?: true} -> :ok
      changeset -> {:error, changeset}
    end
  end

  @doc """
  Updates one scheduling preference on the profile's default availability
  schedule.

  Used by the onboarding wizard, which sets the account's starting policy before
  any additional schedule exists. The wizard submits one field at a time, so
  whichever of the four is present in `params` is the one that is written.
  """
  @spec update_scheduling_preferences(ProfileSchema.t(), %{String.t() => term()}) ::
          {:ok, AvailabilityScheduleSchema.t()} | {:error, term()}
  def update_scheduling_preferences(profile, params) do
    case {Map.take(params, @policy_param_keys), Schedules.get_default(profile.id)} do
      {_policy_params, nil} ->
        {:error, :no_default_schedule}

      {policy_params, schedule} when map_size(policy_params) == 0 ->
        {:ok, schedule}

      {policy_params, schedule} ->
        Schedules.update_policy(schedule, policy_params)
    end
  end

  @doc """
  Updates profile timezone.
  """
  @spec update_timezone(ProfileSchema.t(), String.t()) ::
          {:ok, ProfileSchema.t()} | {:error, term()}
  def update_timezone(profile, timezone) do
    Profiles.update_timezone(profile, timezone)
  end
end
