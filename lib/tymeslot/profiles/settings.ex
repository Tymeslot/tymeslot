defmodule Tymeslot.Profiles.Settings do
  @moduledoc """
  Subcomponent for profile settings updates during onboarding and beyond.
  This module coordinates updates across multiple profile aspects.
  """

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema

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
  Updates profile timezone.
  """
  @spec update_timezone(ProfileSchema.t(), String.t()) ::
          {:ok, ProfileSchema.t()} | {:error, term()}
  def update_timezone(profile, timezone) do
    Profiles.update_timezone(profile, timezone)
  end
end
