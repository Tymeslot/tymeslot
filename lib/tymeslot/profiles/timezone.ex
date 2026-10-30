defmodule Tymeslot.Profiles.Timezone do
  @moduledoc """
  Profiles context helper for timezone decisions: which timezone a profile
  reads its clock in, and what to prefill or persist for a profile that has
  none. Reached through `Tymeslot.Profiles`.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Timezones

  @default_timezone "Europe/Tallinn"

  @doc """
  Determines a prefill timezone given the current profile timezone and a
  detected browser timezone.

  Rules:
  - If the current profile timezone is nil or empty, use the detected
    timezone (normalized).
  - If detected is nil, empty, or not a zone the time-zone database knows
    (it comes from the browser, so it can be anything), fall back to the
    business default.
  - Otherwise, keep the existing profile timezone unchanged.
  """
  @spec prefill_timezone(String.t() | nil, String.t() | nil) :: String.t()
  def prefill_timezone(current_profile_timezone, detected_timezone) do
    default = default()

    if should_use_detected?(current_profile_timezone) do
      detected_timezone
      |> Timezones.normalize()
      |> valid_or_default(default)
    else
      current_profile_timezone
    end
  end

  defp should_use_detected?(nil), do: true
  defp should_use_detected?(""), do: true
  defp should_use_detected?(_current), do: false

  defp valid_or_default(timezone, default) do
    if Timezones.valid?(timezone), do: timezone, else: default
  end

  @doc """
  Gives a profile its prefilled timezone (`prefill_timezone/2`) in memory,
  without persisting it. `nil` for no profile.
  """
  @spec prefill_profile(ProfileSchema.t() | nil, String.t() | nil) :: ProfileSchema.t() | nil
  def prefill_profile(nil, _detected_timezone), do: nil

  def prefill_profile(profile, detected_timezone) do
    prefilled_tz = prefill_timezone(profile.timezone, detected_timezone)
    %{profile | timezone: prefilled_tz}
  end

  @doc "See `Tymeslot.Profiles.ensure_timezone/2`."
  @spec ensure_timezone(ProfileSchema.t(), String.t() | nil) :: {:ok, ProfileSchema.t()}
  def ensure_timezone(%ProfileSchema{} = profile, detected_timezone) do
    case prefill_timezone(profile.timezone, detected_timezone) do
      unchanged when unchanged == profile.timezone ->
        {:ok, profile}

      timezone ->
        case Profiles.update_timezone(profile, timezone) do
          {:ok, updated} ->
            {:ok, updated}

          {:error, reason} ->
            Logger.warning("Could not persist a prefilled profile timezone",
              profile_id: profile.id,
              reason: LogFormat.reason(reason)
            )

            {:ok, profile}
        end
    end
  end

  @doc """
  The timezone for a user, or the default if no profile exists.
  """
  @spec for_user(pos_integer()) :: String.t()
  def for_user(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:error, :not_found} -> default()
      {:ok, profile} -> of(profile)
    end
  end

  @doc """
  A profile's timezone, or the default for a profile that has none set.

  `profiles.timezone` is nullable, so this is the one rule for reading an
  owner's clock: the booking page, time off, the free/busy feed and booking
  limits all go through it, and so agree on where a nil-timezone host's day
  begins. Takes anything carrying `:timezone`, or `nil` for no profile.

  A blank zone, or one the time-zone database does not know
  (`Timezones.valid?/1`), counts as none: every caller can shift into
  whatever this returns.
  """
  @spec of(map() | nil) :: String.t()
  def of(%{timezone: timezone}) when is_binary(timezone) do
    if Timezones.valid?(timezone), do: timezone, else: default()
  end

  def of(_profile), do: default()

  @doc "The business default timezone."
  @spec default() :: String.t()
  def default, do: @default_timezone
end
