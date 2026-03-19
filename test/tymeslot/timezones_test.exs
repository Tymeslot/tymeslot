defmodule Tymeslot.TimezonesTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias Tymeslot.Timezones

  describe "all_options/0" do
    test "returns a non-empty list of {label, timezone_id} tuples" do
      options = Timezones.all_options()
      assert length(options) > 100

      {label, tz_id} = hd(options)
      assert is_binary(label)
      assert is_binary(tz_id)
    end

    test "all timezone IDs are valid" do
      for {_label, tz_id} <- Timezones.all_options() do
        assert Timezones.valid?(tz_id), "Expected #{tz_id} to be valid"
      end
    end
  end

  describe "search/1" do
    test "returns all options (capped at 50) for empty string" do
      results = Timezones.search("")
      assert length(results) == 50

      {label, tz_id, offset} = hd(results)
      assert is_binary(label)
      assert is_binary(tz_id)
      assert is_binary(offset)
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

    test "searches across countries sharing a timezone" do
      results = Timezones.search("Netherlands")
      assert Enum.any?(results, fn {_l, tz, _o} -> tz == "Europe/Brussels" end)
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

    test "maps Berlin to Germany, not Denmark (zone1970 primary country)" do
      assert Timezones.country_code("Europe/Berlin") == :deu
      assert Timezones.format("Europe/Berlin") == "Berlin, Germany"
    end

    test "maps Simferopol to Ukraine (country override for disputed territory)" do
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
    test "normalizes legacy timezone IDs" do
      assert Timezones.normalize("Europe/Kiev") == "Europe/Kyiv"
    end

    test "passes through canonical IDs unchanged" do
      assert Timezones.normalize("Europe/Brussels") == "Europe/Brussels"
    end

    test "handles nil gracefully" do
      assert Timezones.normalize(nil) == nil
    end
  end

  describe "valid?/1" do
    test "returns true for country-based timezones" do
      assert Timezones.valid?("Europe/Brussels")
      assert Timezones.valid?("America/New_York")
    end

    test "returns false for non-country IANA timezones" do
      # UTC and Etc/* zones are valid IANA but not country-based;
      # they have no display label and fall back to the default.
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
      refute MapSet.member?(ids, "Fake/Zone")
    end
  end

  describe "format/1" do
    test "formats known timezone as 'City, Country'" do
      assert Timezones.format("America/New_York") == "New York, United States"
      assert Timezones.format("Europe/Brussels") == "Brussels, Belgium"
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
