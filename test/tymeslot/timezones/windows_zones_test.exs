defmodule Tymeslot.Timezones.WindowsZonesTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Timezones.WindowsZones

  @start ~U[2026-10-05 07:00:00Z]

  describe "from_iana/2" do
    # None of these is its Windows zone's default, and Graph does not list
    # them as IANA names.
    test "names the Windows zone CLDR maps a zone to" do
      for {zone, windows} <- [
            {"Europe/Madrid", "Romance Standard Time"},
            {"Europe/Dublin", "GMT Standard Time"},
            {"Europe/Amsterdam", "W. Europe Standard Time"},
            {"America/Toronto", "Eastern Standard Time"},
            {"Asia/Hong_Kong", "China Standard Time"},
            {"Europe/Berlin", "W. Europe Standard Time"},
            {"Etc/UTC", "UTC"}
          ] do
        assert WindowsZones.from_iana(zone, @start) == windows
      end
    end

    # CLDR spells these the old way, `Asia/Saigon` and `America/Louisville`.
    # Offsets alone would name `Altai Standard Time`, the first Windows zone
    # at UTC+7, for Ho Chi Minh City.
    test "names CLDR's Windows zone for a zone CLDR knows by its old name" do
      assert WindowsZones.from_iana("Asia/Ho_Chi_Minh", @start) == "SE Asia Standard Time"

      assert WindowsZones.from_iana("America/Kentucky/Louisville", @start) ==
               "Eastern Standard Time"
    end

    # Links CLDR does not list, to zones it does (`Europe/Istanbul`,
    # `America/Toronto`). Offsets alone would name `Arab Standard Time`, the
    # first Windows zone at UTC+3, for Istanbul.
    test "names CLDR's Windows zone for a link to a zone CLDR knows" do
      assert WindowsZones.from_iana("Asia/Istanbul", @start) == "Turkey Standard Time"
      assert WindowsZones.from_iana("America/Montreal", @start) == "Eastern Standard Time"
    end

    # Coyhaique left Chile's daylight saving in 2025 and CLDR 47 does not name
    # it: the first Windows zone keeping UTC-3 all year answers.
    test "names a Windows zone keeping the same offsets for a zone CLDR lacks" do
      assert WindowsZones.from_iana("America/Coyhaique", @start) == "Argentina Standard Time"
    end

    test "returns a Windows zone name as given" do
      assert WindowsZones.from_iana("Romance Standard Time", @start) == "Romance Standard Time"
    end

    test "falls back to UTC for a zone the time zone database does not know" do
      assert WindowsZones.from_iana("Nowhere/Zone", @start) == "UTC"
    end
  end
end
