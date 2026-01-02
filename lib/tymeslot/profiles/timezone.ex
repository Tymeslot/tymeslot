defmodule Tymeslot.Profiles.Timezone do
  @moduledoc """
  Profiles context helper for timezone decisions.

  Provides pure functions to determine what timezone should be shown/prefilled
  for a profile, without any dependency on Phoenix or LiveView.
  """

  alias Tymeslot.Profiles
  alias Tymeslot.Utils.TimezoneUtils

  @doc """
  Determines a prefill timezone given the current profile timezone and a
  detected browser timezone.

  Rules:
  - If the current profile timezone is nil, empty, or equals the business
    default, use the detected timezone (normalized).
  - If detected is nil/empty, fall back to the business default.
  - Otherwise, keep the existing profile timezone unchanged.
  """
  @spec prefill_timezone(String.t() | nil, String.t() | nil) :: String.t()
  def prefill_timezone(current_profile_timezone, detected_timezone) do
    default = Profiles.get_default_timezone()

    if should_use_detected?(current_profile_timezone, default) do
      detected_timezone
      |> fallback_default(default)
      |> TimezoneUtils.normalize_timezone()
    else
      current_profile_timezone
    end
  end

  defp should_use_detected?(current, default) do
    is_nil(current) or current == "" or current == default
  end

  defp fallback_default(nil, default), do: default
  defp fallback_default("", default), do: default
  defp fallback_default(tz, _default), do: tz
end
