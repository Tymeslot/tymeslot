defmodule Tymeslot.Timezones.IanaDataTest do
  @moduledoc """
  Guards the vendored IANA time zone release.

  Every slot the scheduler offers is derived from this data, so a stale release
  silently shifts bookings by an hour rather than failing loudly. The `tz`
  package bundles whichever release it shipped with, so Core pins its own
  vendored copy (`config :tz, :iana_version` plus `priv/tz/`). These tests fail
  if the pin and the vendored files drift apart, and cover the two 2026
  transitions that motivated the pin.
  """

  use ExUnit.Case, async: true

  @moduletag :utils

  # `tz` compiles the data in, so this reflects what the running system will
  # actually resolve, not merely what is checked into priv/.
  defp offset_hours(zone, naive) do
    {:ok, datetime} = DateTime.from_naive(naive, zone)
    div(datetime.utc_offset + datetime.std_offset, 3600)
  end

  describe "vendored IANA release" do
    test "the compiled data matches the pinned version" do
      pinned = Application.get_env(:tz, :iana_version)

      assert Tz.iana_version() == pinned,
             """
             The compiled time zone data (#{Tz.iana_version()}) does not match the \
             pinned version (#{inspect(pinned)}).

             After changing :iana_version, vendor the matching files and rebuild:

                 mix tz.download <version> && mix deps.compile tz --force
             """
    end

    test "the pin is not older than the release carrying the 2026 changes" do
      assert Tz.iana_version() >= "2026c"
    end
  end

  describe "Morocco's move to permanent UTC on 2026-09-20" do
    test "still observes +01 the day before" do
      assert offset_hours("Africa/Casablanca", ~N[2026-09-19 12:00:00]) == 1
    end

    test "observes +00 the day after" do
      assert offset_hours("Africa/Casablanca", ~N[2026-09-21 12:00:00]) == 0
    end

    test "no longer shifts around Ramadan in later years" do
      assert offset_hours("Africa/Casablanca", ~N[2027-06-15 12:00:00]) == 0
    end
  end

  describe "Alberta's move to permanent -06 on 2026-11-01" do
    test "observes -06 before the transition" do
      assert offset_hours("America/Edmonton", ~N[2026-10-15 12:00:00]) == -6
    end

    test "stays on -06 through the winter instead of falling back" do
      assert offset_hours("America/Edmonton", ~N[2026-11-15 12:00:00]) == -6
      assert offset_hours("America/Edmonton", ~N[2027-01-15 12:00:00]) == -6
    end

    test "stays on -06 the following summer" do
      assert offset_hours("America/Edmonton", ~N[2027-07-15 12:00:00]) == -6
    end
  end

  describe "British Columbia's move to permanent -07" do
    test "stays on -07 through the winter" do
      assert offset_hours("America/Vancouver", ~N[2027-01-15 12:00:00]) == -7
    end
  end
end
