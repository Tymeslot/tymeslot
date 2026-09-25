defmodule Tymeslot.Profiles.Timezone do
  @moduledoc """
  Profiles context helper for timezone decisions.

  Provides pure functions to determine what timezone should be shown/prefilled
  for a profile, without any dependency on Phoenix or LiveView.
  """

  alias Tymeslot.Profiles
  alias Tymeslot.Timezones

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
    default = Profiles.get_default_timezone()

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
end
