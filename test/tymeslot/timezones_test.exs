defmodule Tymeslot.TimezonesTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias Tymeslot.Timezones

  describe "all_options/0" do
    test "returns a non-empty list of {label, timezone_id} tuples" do
      options = Timezones.all_options()
      assert length(options) > 80

      {label, tz_id} = hd(options)
      assert is_binary(label)
      assert is_binary(tz_id)
    end

    test "all timezone IDs are valid" do
      for {_label, tz_id} <- Timezones.all_options() do
        assert Timezones.valid?(tz_id), "Expected #{tz_id} to be valid"
      end
    end

    test "options are sorted alphabetically by label" do
      labels = Enum.map(Timezones.all_options(), fn {label, _tz_id} -> label end)
      assert labels == Enum.sort(labels)
    end
  end

  describe "search/1" do
    test "returns all options with popular timezones first for empty string" do
      results = Timezones.search("")
      assert length(results) > 50

      {label, tz_id, offset} = hd(results)
      assert is_binary(label)
      assert is_binary(tz_id)
      assert is_binary(offset)

      # Popular timezones appear before the alphabetical rest
      tz_ids = Enum.map(results, fn {_l, id, _o} -> id end)
      la_idx = Enum.find_index(tz_ids, &(&1 == "America/Los_Angeles"))
      tokyo_idx = Enum.find_index(tz_ids, &(&1 == "Asia/Tokyo"))
      assert la_idx < tokyo_idx
    end

    test "filters by city name" do
      results = Timezones.search("Brussels")
      assert results != []

      assert Enum.any?(results, fn {_label, tz_id, _offset} ->
               tz_id == "Europe/Brussels"
             end)
    end

    test "finds timezone via search alias" do
      results = Timezones.search("Mumbai")
      assert Enum.any?(results, fn {_l, tz, _o} -> tz == "Asia/Kolkata" end)
    end

    test "finds Amsterdam as its own entry" do
      results = Timezones.search("Amsterdam")
      assert Enum.any?(results, fn {_l, tz, _o} -> tz == "Europe/Amsterdam" end)
    end

    test "finds Netherlands and returns Amsterdam" do
      results = Timezones.search("Netherlands")
      assert Enum.any?(results, fn {_l, tz, _o} -> tz == "Europe/Amsterdam" end)
    end

    test "finds Stockholm, Oslo, Copenhagen as own entries" do
      for {query, expected_tz} <- [
            {"Stockholm", "Europe/Stockholm"},
            {"Oslo", "Europe/Oslo"},
            {"Copenhagen", "Europe/Copenhagen"}
          ] do
        results = Timezones.search(query)

        assert Enum.any?(results, fn {_l, tz, _o} -> tz == expected_tz end),
               "Expected #{expected_tz} in results for '#{query}'"
      end
    end

    test "limits results to 50" do
      results = Timezones.search("a")
      assert length(results) <= 50
    end
  end

  describe "country_code/1" do
    test "returns alpha-3 atom for known timezone" do
      assert Timezones.country_code("Europe/Brussels") == :bel
      assert Timezones.country_code("America/New_York") == :usa
      assert Timezones.country_code("Asia/Tokyo") == :jpn
    end

    test "returns correct country for cities that are IANA links" do
      assert Timezones.country_code("Europe/Amsterdam") == :nld
      assert Timezones.country_code("Europe/Stockholm") == :swe
      assert Timezones.country_code("Europe/Oslo") == :nor
      assert Timezones.country_code("Europe/Copenhagen") == :dnk
    end

    test "maps Berlin to Germany" do
      assert Timezones.country_code("Europe/Berlin") == :deu
      assert Timezones.format("Europe/Berlin") == "Berlin, Germany"
    end

    test "maps Simferopol to Ukraine" do
      assert Timezones.country_code("Europe/Simferopol") == :ukr
      assert Timezones.format("Europe/Simferopol") == "Simferopol, Ukraine"
    end

    test "returns nil for unknown timezone" do
      assert Timezones.country_code("Fake/Zone") == nil
    end

    test "returns nil for non-string input" do
      assert Timezones.country_code(nil) == nil
      assert Timezones.country_code(42) == nil
    end
  end

  describe "normalize/1" do
    test "normalizes legacy Europe/Kiev to Europe/Kyiv" do
      assert Timezones.normalize("Europe/Kiev") == "Europe/Kyiv"
    end

    test "passes through canonical and link IDs unchanged" do
      assert Timezones.normalize("Europe/Brussels") == "Europe/Brussels"
      assert Timezones.normalize("Europe/Amsterdam") == "Europe/Amsterdam"
    end

    test "handles nil gracefully" do
      assert Timezones.normalize(nil) == nil
    end
  end

  describe "valid?/1" do
    test "returns true for canonical timezones" do
      assert Timezones.valid?("Europe/Brussels")
      assert Timezones.valid?("America/New_York")
    end

    test "returns true for IANA link cities in our list" do
      assert Timezones.valid?("Europe/Amsterdam")
      assert Timezones.valid?("Europe/Stockholm")
      assert Timezones.valid?("Atlantic/Reykjavik")
    end

    test "returns false for non-country IANA timezones" do
      refute Timezones.valid?("UTC")
      refute Timezones.valid?("Etc/UTC")
    end

    test "returns false for invalid timezone" do
      refute Timezones.valid?("Fake/Zone")
      refute Timezones.valid?("")
    end

    test "returns false for non-string input" do
      refute Timezones.valid?(nil)
      refute Timezones.valid?(42)
    end
  end

  describe "valid_ids/0" do
    test "returns a MapSet" do
      ids = Timezones.valid_ids()
      assert %MapSet{} = ids
      assert MapSet.member?(ids, "Europe/Brussels")
      assert MapSet.member?(ids, "Europe/Amsterdam")
      refute MapSet.member?(ids, "Fake/Zone")
    end
  end

  describe "format/1" do
    test "formats known timezone as 'City, Country'" do
      assert Timezones.format("America/New_York") == "New York, United States"
      assert Timezones.format("Europe/Brussels") == "Brussels, Belgium"
      assert Timezones.format("Europe/Amsterdam") == "Amsterdam, Netherlands"
    end

    test "normalizes before formatting" do
      assert Timezones.format("Europe/Kiev") == "Kyiv, Ukraine"
    end

    test "falls back for unknown timezone" do
      assert Timezones.format("Unknown/Zone") == "Zone"
    end

    test "returns fallback for non-string" do
      assert Timezones.format(nil) == "Unknown timezone"
    end
  end

  describe "utc_offset/1" do
    test "returns a UTC offset string" do
      offset = Timezones.utc_offset("Europe/Brussels")
      assert offset =~ ~r/^UTC[+-±]/
    end

    test "returns UTC for invalid timezone" do
      assert Timezones.utc_offset("Fake/Zone") == "UTC"
    end
  end

  describe "format_utc_offset/1" do
    test "formats zero offset" do
      assert Timezones.format_utc_offset(0) == "UTC±0"
    end

    test "formats positive offset" do
      assert Timezones.format_utc_offset(3600) == "UTC+1"
      assert Timezones.format_utc_offset(19_800) == "UTC+5:30"
    end

    test "formats negative offset" do
      assert Timezones.format_utc_offset(-18_000) == "UTC-5"
      assert Timezones.format_utc_offset(-12_600) == "UTC-3:30"
    end
  end

  describe "sanitize/1" do
    test "returns nil for nil, non-binary, or blank input" do
      assert Timezones.sanitize(nil) == nil
      assert Timezones.sanitize("") == nil
      assert Timezones.sanitize("   ") == nil
      assert Timezones.sanitize(~s("")) == nil
      assert Timezones.sanitize(42) == nil
    end

    test "strips surrounding double quotes (Zimbra-style quoted TZID)" do
      assert Timezones.sanitize(~s("Europe/Brussels")) == "Europe/Brussels"
      assert Timezones.sanitize(~s("Europe/Paris")) == "Europe/Paris"
    end

    test "trims whitespace outside and inside quotes" do
      assert Timezones.sanitize("  Europe/Brussels  ") == "Europe/Brussels"
      assert Timezones.sanitize(~s(  "Europe/Brussels"  )) == "Europe/Brussels"
      assert Timezones.sanitize(~s(" Europe/Brussels ")) == "Europe/Brussels"
    end

    test "leaves plain IANA timezone strings untouched" do
      assert Timezones.sanitize("Europe/Paris") == "Europe/Paris"
      assert Timezones.sanitize("America/New_York") == "America/New_York"
      assert Timezones.sanitize("Etc/UTC") == "Etc/UTC"
    end

    test "applies legacy IANA normalisation" do
      assert Timezones.sanitize("Europe/Kiev") == "Europe/Kyiv"
      assert Timezones.sanitize(~s("Europe/Kiev")) == "Europe/Kyiv"
    end

    test "maps Windows zone names to IANA" do
      assert Timezones.sanitize("Romance Standard Time") == "Europe/Paris"
      assert Timezones.sanitize("W. Europe Standard Time") == "Europe/Berlin"
      assert Timezones.sanitize("GMT Standard Time") == "Europe/London"
      assert Timezones.sanitize("Pacific Standard Time") == "America/Los_Angeles"
      assert Timezones.sanitize("Eastern Standard Time") == "America/New_York"
      assert Timezones.sanitize("Tokyo Standard Time") == "Asia/Tokyo"
      assert Timezones.sanitize("FLE Standard Time") == "Europe/Kyiv"
      assert Timezones.sanitize("UTC") == "Etc/UTC"
    end

    test "leaves unrecognised strings as-is (validation is downstream)" do
      assert Timezones.sanitize("not-a-real-zone") == "not-a-real-zone"
      assert Timezones.sanitize("Mars/Olympus_Mons") == "Mars/Olympus_Mons"
    end
  end

  describe "flag_exists?/1" do
    test "returns true for known flag" do
      assert Timezones.flag_exists?(:usa)
      assert Timezones.flag_exists?(:bel)
    end

    test "returns false for nil" do
      refute Timezones.flag_exists?(nil)
    end

    test "returns false for non-atom" do
      refute Timezones.flag_exists?("usa")
    end
  end
end
