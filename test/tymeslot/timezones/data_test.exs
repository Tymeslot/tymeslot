defmodule Tymeslot.Timezones.DataTest do
  @moduledoc """
  Covers what the timezone picker offers and how it is searched.

  The list is a presentation layer over IANA: a zone can resolve perfectly and
  still be unreachable because no entry names it, which is how the French
  overseas departments went missing. These tests pin both halves — the entry
  exists, and the spelling a local actually types finds it.
  """

  use ExUnit.Case, async: true

  @moduletag :utils

  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Timezones
  alias Tymeslot.Timezones.Data

  defp found(term), do: Enum.map(Data.search(term), &elem(&1, 1))

  defp offsets(term), do: Map.new(Data.search(term), fn {_label, id, offset} -> {id, offset} end)

  describe "French overseas departments" do
    # Each is its own IANA zone, and each is somebody's working day: these are
    # not edge cases for a scheduler sold in France.
    test "are offered with a label and a country" do
      for {zone, label} <- [
            {"Indian/Reunion", "Saint-Denis, Reunion"},
            {"Indian/Mayotte", "Mamoudzou, Mayotte"},
            {"America/Guadeloupe", "Pointe-a-Pitre, Guadeloupe"},
            {"America/Martinique", "Fort-de-France, Martinique"},
            {"America/Cayenne", "Cayenne, French Guiana"}
          ] do
        assert Data.valid?(zone)
        assert Data.display_name(zone) == label
        assert Data.country_code(zone) != nil, "#{zone} has no country code, so no flag"
      end
    end

    test "answer to the name and the number people use" do
      assert "Indian/Reunion" in found("la réunion")
      assert "Indian/Reunion" in found("974")
      assert "America/Martinique" in found("972")
      assert "America/Cayenne" in found("guyane")
      assert "Indian/Mayotte" in found("976")
    end
  end

  describe "search/1 with nothing typed yet" do
    # The unfiltered list is what onboarding, profile settings and the booking
    # page show first, and people pick a zone by its offset there.
    test "labels each zone with the offset in force today, not when the release was built" do
      freeze_clock(~U[2027-01-15 12:00:00Z])
      assert offsets("")["Europe/Berlin"] == "UTC+1"
      assert offsets("")["America/New_York"] == "UTC-5"

      freeze_clock(~U[2027-07-15 12:00:00Z])
      assert offsets("")["Europe/Berlin"] == "UTC+2"
      assert offsets("")["America/New_York"] == "UTC-4"
    end

    test "agrees with a typed search for the same zone" do
      freeze_clock(~U[2027-01-15 12:00:00Z])
      assert offsets("")["Europe/Berlin"] == offsets("Berlin")["Europe/Berlin"]
    end
  end

  describe "utc_offset/2" do
    test "reads the offset in force at the given instant" do
      assert Timezones.utc_offset("Australia/Sydney", ~U[2027-01-15 12:00:00Z]) == "UTC+11"
      assert Timezones.utc_offset("Australia/Sydney", ~U[2027-07-15 12:00:00Z]) == "UTC+10"
      assert Timezones.utc_offset("Asia/Kolkata", ~U[2027-07-15 12:00:00Z]) == "UTC+5:30"
    end
  end

  describe "search/1" do
    test "ignores diacritics in the query" do
      # The list is written without accents; the people typing into it are not.
      assert "Indian/Reunion" in found("Réunion")
      assert "America/Guadeloupe" in found("Pointe-à-Pitre")
      assert "America/Sao_Paulo" in found("São Paulo")
      assert "Europe/Zurich" in found("Zürich")
    end

    test "still matches the unaccented spelling" do
      assert "America/Sao_Paulo" in found("sao paulo")
      assert "Europe/Zurich" in found("zurich")
      assert "Europe/Paris" in found("paris")
    end

    test "is case-insensitive and matches a country as well as a city" do
      assert "Europe/Paris" in found("FRANCE")
      assert "Indian/Reunion" in found("SAINT-DENIS")
    end

    test "returns nothing for a term no entry carries" do
      assert found("zzzzz") == []
    end
  end
end
