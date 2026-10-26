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

  alias Tymeslot.Locales
  alias Tymeslot.Timezones
  alias Tymeslot.Timezones.Cities.{Africa, Americas, Asia, Europe, Oceania}
  alias Tymeslot.Timezones.{Data, PlaceNames}

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

    test "matches an IANA id" do
      assert "America/Sao_Paulo" in found("America/Sao_Paulo")
    end
  end

  describe "in another locale" do
    # Labels and search answer in the current Gettext locale, which each
    # request sets; English is the fallback for a locale with no place names.
    defp in_locale(locale, fun), do: Gettext.with_locale(TymeslotWeb.Gettext, locale, fun)

    test "labels a zone with the city and country in that language" do
      assert in_locale("de", fn -> Data.display_name("Europe/Berlin") end) ==
               "Berlin, Deutschland"

      assert in_locale("uk", fn -> Data.display_name("Europe/Kyiv") end) == "Київ, Україна"
      assert in_locale("de", fn -> Data.display_name("Europe/Kyiv") end) == "Kyjiw, Ukraine"
      assert Data.display_name("Europe/Kyiv") == "Kyiv, Ukraine"
      assert in_locale("pt", fn -> Timezones.format("America/Sao_Paulo") end) =~ "São Paulo"
    end

    test "keeps the label when the locale has no place names" do
      assert in_locale("pseudo", fn -> Data.display_name("Europe/Berlin") end) ==
               "Berlin, Germany"
    end

    test "offers every zone, labelled in that language" do
      options = in_locale("de", fn -> Data.all_options() end)

      assert length(options) == length(Data.all_options())
      assert {"Wien, Österreich", "Europe/Vienna"} in options
    end

    test "sorts the options ignoring accents" do
      # By code point, "Řím" and "Šanghaj" would follow every Z.
      labels = in_locale("cs", fn -> Enum.map(Data.all_options(), &elem(&1, 0)) end)
      rome = Enum.find_index(labels, &String.starts_with?(&1, "Řím"))
      first_t = Enum.find_index(labels, &String.starts_with?(&1, "T"))

      assert rome != nil and first_t != nil
      assert rome < first_t
    end

    test "sorts Ukrainian options in the Ukrainian alphabet" do
      # By code point, Є and І would follow Я; folded, Й would merge into И.
      labels = in_locale("uk", fn -> Enum.map(Data.all_options(), &elem(&1, 0)) end)
      index = fn label -> Enum.find_index(labels, &String.starts_with?(&1, label)) end

      assert index.("Душанбе") < index.("Єкатеринбург")
      assert index.("Єрусалим") < index.("Загреб")
      assert index.("Іркутськ") < index.("Йоганнесбурґ")
      assert index.("Йоганнесбурґ") < index.("Кабул")
      assert index.("Каєнна") < index.("Калінінград")
    end

    test "writes every Ukrainian city in Cyrillic" do
      # A city CLDR files under an older zone id (Indianapolis, Louisville) or
      # does not name at all (Montreal) otherwise falls back to English.
      latin =
        in_locale("uk", fn -> Data.all_options() end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(&1 =~ ~r/[A-Za-z]/))

      assert latin == []
    end

    test "finds a zone by its local name, its English name and an alias" do
      in_locale("pl", fn ->
        assert "America/New_York" in found("Nowy Jork")
        assert "America/New_York" in found("New York")
        assert "Asia/Kolkata" in found("mumbai")
      end)
    end

    test "finds Kyiv by the spellings people still type" do
      in_locale("fr", fn ->
        assert "Europe/Kyiv" in found("Kiev")
        assert "Europe/Kyiv" in found("Kiew")
      end)
    end

    test "answers with labels in that language" do
      results = in_locale("de", fn -> Data.search("Wien") end)
      assert {"Wien, Österreich", "Europe/Vienna"} in Enum.map(results, &Tuple.delete_at(&1, 2))
    end

    test "names every city and country in every supported locale" do
      places =
        Americas.cities() ++
          Europe.cities() ++ Asia.cities() ++ Africa.cities() ++ Oceania.cities()

      for locale <- Locales.supported_codes() -- ["en"] do
        missing =
          for {tz_id, _city, _country, country_code} <- places,
              PlaceNames.city(locale, tz_id) == nil or
                PlaceNames.country(locale, country_code) == nil,
              do: tz_id

        assert missing == [], "priv/cldr/place_names/#{locale}.json lacks #{inspect(missing)}"
      end
    end
  end
end
