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
  - If detected is nil/empty, fall back to the business default.
  - Otherwise, keep the existing profile timezone unchanged.
  """
  @spec prefill_timezone(String.t() | nil, String.t() | nil) :: String.t()
  def prefill_timezone(current_profile_timezone, detected_timezone) do
    default = Profiles.get_default_timezone()

    if should_use_detected?(current_profile_timezone, default) do
      detected_timezone
      |> fallback_default(default)
      |> Timezones.normalize()
    else
      current_profile_timezone
    end
  end

  defp should_use_detected?(current, _default) do
    is_nil(current) or current == ""
  end

  defp fallback_default(nil, default), do: default
  defp fallback_default("", default), do: default
  defp fallback_default(tz, _default), do: tz
end
