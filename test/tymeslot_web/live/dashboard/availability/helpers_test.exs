defmodule TymeslotWeb.Dashboard.Availability.HelpersTest do
  @moduledoc """
  Coverage for `get_timezone_info/1`, which feeds the flag-and-label pair the
  availability views render above the schedule.

  Its old fallback tested the *profile* for presence rather than the timezone
  (`if profile, do: profile.timezone, else: "UTC"`), so a profile row whose
  `timezone` column was still null — the state onboarding leaves behind if the
  browser never reported one — passed nil straight into `Timezones.format/1`
  and `Timezones.country_code/1` instead of falling back at all.
  """

  use ExUnit.Case, async: true

  @moduletag :utils

  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.Dashboard.Availability.Helpers

  describe "get_timezone_info/1" do
    test "uses the profile's timezone when it has one" do
      info = Helpers.get_timezone_info(%ProfileSchema{timezone: "Europe/Kyiv"})

      assert info.timezone == "Europe/Kyiv"
      assert info.timezone_display == "Kyiv, Ukraine"
      assert info.country_code == :ukr
    end

    test "falls back when the profile has no timezone set" do
      info = Helpers.get_timezone_info(%ProfileSchema{timezone: nil})

      assert info.timezone == "Etc/UTC"
      assert info.timezone_display == "UTC"
    end

    test "falls back when there is no profile at all" do
      info = Helpers.get_timezone_info(nil)

      assert info.timezone == "Etc/UTC"
      assert info.timezone_display == "UTC"
    end
  end
end
