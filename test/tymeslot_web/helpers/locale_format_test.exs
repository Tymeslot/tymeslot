defmodule TymeslotWeb.Helpers.LocaleFormatTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Helpers.LocaleFormat

  # The space-grouping locales group with U+00A0, not a plain space, so a
  # figure cannot wrap mid-number. Spelled out here so an expectation that
  # merely looks right cannot pass against the wrong character.
  @nbsp "\u00A0"

  describe "format_date/2" do
    test "formats date in English" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "en") == "15 March 2026"
    end

    test "formats date in German" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "de") == "15. März 2026"
    end

    test "formats date in Ukrainian" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "uk") == "15 березня 2026"
    end

    test "formats date in French" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "fr") == "15 mars 2026"
    end

    test "formats date in Italian" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "it") == "15 marzo 2026"
    end

    test "formats date in Polish with the genitive month" do
      assert LocaleFormat.format_date(~D[2026-04-05], "pl") == "5 kwietnia 2026"
      assert LocaleFormat.format_date(~D[2026-03-15], "pl") == "15 marca 2026"
    end

    test "formats date in Spanish with a lowercase month" do
      assert LocaleFormat.format_date(~D[2026-04-05], "es") == "5 de abril de 2026"
      assert LocaleFormat.format_date(~D[2026-09-15], "es") == "15 de septiembre de 2026"
    end

    test "falls back to English for unknown locale" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "ja") == "15 March 2026"
    end

    test "writes the first of a month as an ordinal in French, Italian and Portuguese" do
      assert LocaleFormat.format_date(~D[2026-10-01], "fr") == "1er octobre 2026"
      assert LocaleFormat.format_date(~D[2026-10-01], "it") == "1° ottobre 2026"
      assert LocaleFormat.format_date(~D[2026-10-01], "pt") == "1º de outubro de 2026"
    end

    test "keeps the first of a month a plain number elsewhere, with German's single stop" do
      assert LocaleFormat.format_date(~D[2026-10-01], "en") == "1 October 2026"
      assert LocaleFormat.format_date(~D[2026-10-01], "de") == "1. Oktober 2026"
      assert LocaleFormat.format_date(~D[2026-10-01], "cs") == "1. října 2026"
    end
  end

  describe "format_time/2" do
    test "formats time in 12-hour format for English" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "en") == "02:30 PM"
    end

    test "formats time in 24-hour format for German" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "de") == "14:30"
    end

    test "formats time in 24-hour format for Ukrainian" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "uk") == "14:30"
    end

    test "handles midnight correctly in English" do
      time = ~T[00:00:00]
      assert LocaleFormat.format_time(time, "en") == "12:00 AM"
    end

    test "handles midnight correctly in German" do
      time = ~T[00:00:00]
      assert LocaleFormat.format_time(time, "de") == "00:00"
    end

    test "handles noon correctly in English" do
      time = ~T[12:00:00]
      assert LocaleFormat.format_time(time, "en") == "12:00 PM"
    end

    test "formats time in 24-hour format for French" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "fr") == "14:30"
    end

    test "formats time in 24-hour format for Italian" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "it") == "14:30"
    end

    test "formats time in 24-hour format for Polish" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "pl") == "14:30"
    end

    test "formats time in 24-hour format for Spanish" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "es") == "14:30"
    end

    test "falls back to English for unknown locale" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "ja") == "02:30 PM"
    end
  end

  describe "get_month_names/1" do
    test "returns English month names" do
      months = LocaleFormat.get_month_names("en")
      assert length(months) == 12
      assert Enum.at(months, 0) == "January"
      assert Enum.at(months, 11) == "December"
    end

    test "returns German month names" do
      months = LocaleFormat.get_month_names("de")
      assert length(months) == 12
      assert Enum.at(months, 0) == "Januar"
      assert Enum.at(months, 2) == "März"
      assert Enum.at(months, 11) == "Dezember"
    end

    test "returns Ukrainian month names in genitive case" do
      months = LocaleFormat.get_month_names("uk")
      assert length(months) == 12
      assert Enum.at(months, 0) == "січня"
      assert Enum.at(months, 11) == "грудня"
    end

    test "returns French month names" do
      months = LocaleFormat.get_month_names("fr")
      assert length(months) == 12
      assert Enum.at(months, 0) == "janvier"
      assert Enum.at(months, 2) == "mars"
      assert Enum.at(months, 7) == "août"
      assert Enum.at(months, 11) == "décembre"
    end

    test "returns Italian month names" do
      months = LocaleFormat.get_month_names("it")
      assert length(months) == 12
      assert Enum.at(months, 0) == "gennaio"
      assert Enum.at(months, 2) == "marzo"
      assert Enum.at(months, 7) == "agosto"
      assert Enum.at(months, 11) == "dicembre"
    end

    test "returns Polish month names in genitive case" do
      months = LocaleFormat.get_month_names("pl")
      assert length(months) == 12
      assert Enum.at(months, 0) == "stycznia"
      assert Enum.at(months, 3) == "kwietnia"
      assert Enum.at(months, 8) == "września"
      assert Enum.at(months, 11) == "grudnia"
    end

    test "falls back to English for unknown locale" do
      months = LocaleFormat.get_month_names("ja")
      assert Enum.at(months, 0) == "January"
    end
  end

  describe "get_month_names/2 short format" do
    test "returns 12 short English month names including Jan and Dec" do
      months = LocaleFormat.get_month_names("en", :short)
      assert length(months) == 12
      assert "Jan" in months
      assert "Dec" in months
      assert Enum.at(months, 0) == "Jan"
      assert Enum.at(months, 11) == "Dec"
    end

    test "returns 12 short German month names" do
      months = LocaleFormat.get_month_names("de", :short)
      assert length(months) == 12
      assert Enum.at(months, 0) == "Jan"
      assert Enum.at(months, 11) == "Dez"
    end

    test "short names differ from full names for a locale" do
      assert LocaleFormat.get_month_names("de", :short) !=
               LocaleFormat.get_month_names("de", :full)
    end

    test "defaults to full format when not specified" do
      assert LocaleFormat.get_month_names("en") == LocaleFormat.get_month_names("en", :full)
    end

    test "falls back to English for unknown locale in short format" do
      months = LocaleFormat.get_month_names("ja", :short)
      assert Enum.at(months, 0) == "Jan"
      assert Enum.at(months, 11) == "Dec"
    end
  end

  describe "get_weekday_names/2" do
    test "returns English full weekday names" do
      weekdays = LocaleFormat.get_weekday_names("en", :full)
      assert length(weekdays) == 7
      assert Enum.at(weekdays, 0) == "Sunday"
      assert Enum.at(weekdays, 1) == "Monday"
    end

    test "returns German full weekday names" do
      weekdays = LocaleFormat.get_weekday_names("de", :full)
      assert Enum.at(weekdays, 0) == "Sonntag"
      assert Enum.at(weekdays, 1) == "Montag"
    end

    test "returns short weekday names" do
      weekdays = LocaleFormat.get_weekday_names("en", :short)
      assert Enum.at(weekdays, 0) == "Sun"
      assert Enum.at(weekdays, 1) == "Mon"
    end

    test "returns narrow weekday names" do
      weekdays = LocaleFormat.get_weekday_names("en", :narrow)
      assert Enum.at(weekdays, 0) == "S"
      assert Enum.at(weekdays, 1) == "M"
    end

    test "returns Spanish weekday names, with X for miércoles" do
      assert Enum.at(LocaleFormat.get_weekday_names("es", :full), 3) == "miércoles"
      assert Enum.at(LocaleFormat.get_weekday_names("es", :short), 3) == "mié"
      assert LocaleFormat.get_weekday_names("es", :narrow) == ~w(D L M X J V S)
    end

    test "defaults to short format when not specified" do
      weekdays = LocaleFormat.get_weekday_names("en")
      assert Enum.at(weekdays, 0) == "Sun"
    end
  end

  describe "format_month_name/2" do
    test "formats valid month numbers" do
      assert LocaleFormat.format_month_name(1, "en") == "January"
      assert LocaleFormat.format_month_name(3, "en") == "March"
      assert LocaleFormat.format_month_name(10, "en") == "October"
      assert LocaleFormat.format_month_name(12, "en") == "December"
      assert LocaleFormat.format_month_name(3, "de") == "März"
    end

    test "returns empty string for invalid month numbers" do
      assert LocaleFormat.format_month_name(0, "en") == ""
      assert LocaleFormat.format_month_name(13, "en") == ""
      assert LocaleFormat.format_month_name(-1, "en") == ""
    end

    test "handles edge case month numbers" do
      assert LocaleFormat.format_month_name(nil, "en") == ""
      assert LocaleFormat.format_month_name("invalid", "en") == ""
    end
  end

  describe "format_month_name/3 with :short format" do
    test "formats short month names in English" do
      assert LocaleFormat.format_month_name(1, "en", :short) == "Jan"
      assert LocaleFormat.format_month_name(12, "en", :short) == "Dec"
    end

    test "formats short month name in German" do
      assert LocaleFormat.format_month_name(3, "de", :short) == "März"
    end

    test "formats full month name in German" do
      assert LocaleFormat.format_month_name(1, "de", :full) == "Januar"
    end

    test "short differs from full for the same month and locale" do
      short = LocaleFormat.format_month_name(1, "de", :short)
      full = LocaleFormat.format_month_name(1, "de", :full)
      assert short == "Jan"
      assert full == "Januar"
      assert short != full
    end

    test "returns empty string for invalid month numbers in short format" do
      assert LocaleFormat.format_month_name(13, "en", :short) == ""
      assert LocaleFormat.format_month_name(0, "de", :short) == ""
    end

    test "defaults to full format for back-compat when format omitted" do
      assert LocaleFormat.format_month_name(1, "en") == "January"
      assert LocaleFormat.format_month_name(1, "de") == "Januar"
    end
  end

  describe "format_weekday_name/3" do
    test "formats valid weekday numbers (ISO 8601: 1=Monday, 7=Sunday)" do
      assert LocaleFormat.format_weekday_name(1, "en", :full) == "Monday"
      assert LocaleFormat.format_weekday_name(7, "en", :full) == "Sunday"
    end

    test "converts ISO weekday to correct array index" do
      # ISO: 1=Monday, but our array is 0=Sunday
      assert LocaleFormat.format_weekday_name(1, "en", :short) == "Mon"
      assert LocaleFormat.format_weekday_name(7, "en", :short) == "Sun"
    end

    test "returns empty string for invalid weekday numbers" do
      assert LocaleFormat.format_weekday_name(0, "en", :full) == ""
      assert LocaleFormat.format_weekday_name(8, "en", :full) == ""
      assert LocaleFormat.format_weekday_name(-1, "en", :full) == ""
    end

    test "handles edge case weekday numbers" do
      assert LocaleFormat.format_weekday_name(nil, "en", :full) == ""
      assert LocaleFormat.format_weekday_name("invalid", "en", :full) == ""
    end
  end

  describe "format_day_of_month/2" do
    test "writes the first of a month as an ordinal in French, Italian and Portuguese" do
      assert LocaleFormat.format_day_of_month(1, "fr") == "1er"
      assert LocaleFormat.format_day_of_month(1, "it") == "1°"
      assert LocaleFormat.format_day_of_month(1, "pt") == "1º"
    end

    test "writes the first as a plain number in the other locales" do
      for locale <- ~w(en de uk cs pl es) do
        assert {locale, LocaleFormat.format_day_of_month(1, locale)} == {locale, "1"}
      end
    end

    test "writes every later day as a plain number in every locale" do
      for locale <- ~w(en de fr it uk cs pl pt es), day <- [2, 13, 31] do
        assert {locale, LocaleFormat.format_day_of_month(day, locale)} ==
                 {locale, Integer.to_string(day)}
      end
    end
  end

  describe "DST transition handling" do
    test "formats time during DST transition - Time type is DST-agnostic" do
      # Time (without timezone) should always format consistently
      time = ~T[02:30:00]

      assert LocaleFormat.format_time(time, "en") == "02:30 AM"
      assert LocaleFormat.format_time(time, "de") == "02:30"
      assert LocaleFormat.format_time(time, "uk") == "02:30"
    end
  end

  describe "French locale" do
    test "returns French full weekday names" do
      weekdays = LocaleFormat.get_weekday_names("fr", :full)
      assert length(weekdays) == 7
      assert Enum.at(weekdays, 0) == "dimanche"
      assert Enum.at(weekdays, 1) == "lundi"
      assert Enum.at(weekdays, 6) == "samedi"
    end

    test "returns French short weekday names" do
      weekdays = LocaleFormat.get_weekday_names("fr", :short)
      assert weekdays == ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."]
    end

    test "returns French narrow weekday names" do
      weekdays = LocaleFormat.get_weekday_names("fr", :narrow)
      assert weekdays == ["D", "L", "M", "M", "J", "V", "S"]
    end

    test "formats numbers with space thousand separator and comma decimal" do
      assert LocaleFormat.format_number(1234.56, "fr", 2) == "1#{@nbsp}234,56"
    end

    test "formats month name in French" do
      assert LocaleFormat.format_month_name(1, "fr") == "janvier"
      assert LocaleFormat.format_month_name(8, "fr") == "août"
    end

    test "formats weekday name in French" do
      assert LocaleFormat.format_weekday_name(1, "fr", :full) == "lundi"
      assert LocaleFormat.format_weekday_name(7, "fr", :full) == "dimanche"
    end
  end

  describe "Italian locale" do
    test "returns Italian full weekday names" do
      weekdays = LocaleFormat.get_weekday_names("it", :full)
      assert length(weekdays) == 7
      assert Enum.at(weekdays, 0) == "domenica"
      assert Enum.at(weekdays, 1) == "lunedì"
      assert Enum.at(weekdays, 6) == "sabato"
    end

    test "returns Italian short weekday names" do
      weekdays = LocaleFormat.get_weekday_names("it", :short)
      assert Enum.at(weekdays, 0) == "dom"
      assert Enum.at(weekdays, 1) == "lun"
    end

    test "returns Italian narrow weekday names" do
      weekdays = LocaleFormat.get_weekday_names("it", :narrow)
      assert weekdays == ["D", "L", "M", "M", "G", "V", "S"]
    end

    test "formats numbers with period thousand separator and comma decimal" do
      assert LocaleFormat.format_number(1234.56, "it", 2) == "1.234,56"
    end

    test "formats month name in Italian" do
      assert LocaleFormat.format_month_name(1, "it") == "gennaio"
      assert LocaleFormat.format_month_name(8, "it") == "agosto"
    end

    test "formats weekday name in Italian" do
      assert LocaleFormat.format_weekday_name(1, "it", :full) == "lunedì"
      assert LocaleFormat.format_weekday_name(7, "it", :full) == "domenica"
    end
  end

  describe "Polish locale" do
    test "returns Polish full weekday names" do
      weekdays = LocaleFormat.get_weekday_names("pl", :full)
      assert length(weekdays) == 7
      assert Enum.at(weekdays, 0) == "niedziela"
      assert Enum.at(weekdays, 1) == "poniedziałek"
      assert Enum.at(weekdays, 6) == "sobota"
    end

    test "returns Polish short weekday names" do
      weekdays = LocaleFormat.get_weekday_names("pl", :short)
      assert weekdays == ["niedz.", "pon.", "wt.", "śr.", "czw.", "pt.", "sob."]
    end

    test "returns Polish narrow weekday names" do
      weekdays = LocaleFormat.get_weekday_names("pl", :narrow)
      assert weekdays == ["N", "P", "W", "Ś", "C", "P", "S"]
    end

    test "returns Polish short month names" do
      months = LocaleFormat.get_month_names("pl", :short)
      assert length(months) == 12
      assert Enum.at(months, 3) == "kwi"
      assert Enum.at(months, 9) == "paź"
    end

    test "formats numbers with non-breaking space thousand separator and comma decimal" do
      assert LocaleFormat.format_number(1234.56, "pl", 2) == "1#{@nbsp}234,56"
    end

    test "formats month name in Polish" do
      assert LocaleFormat.format_month_name(1, "pl") == "stycznia"
      assert LocaleFormat.format_month_name(9, "pl") == "września"
    end

    test "formats weekday name in Polish" do
      assert LocaleFormat.format_weekday_name(1, "pl", :full) == "poniedziałek"
      assert LocaleFormat.format_weekday_name(7, "pl", :full) == "niedziela"
    end
  end

  describe "format_date_range/3" do
    test "formats a same-month range in Polish without a day period" do
      assert LocaleFormat.format_date_range(~D[2026-04-10], ~D[2026-04-12], "pl") ==
               "10–12 kwietnia 2026"
    end

    test "formats a cross-month range in Polish" do
      assert LocaleFormat.format_date_range(~D[2026-04-30], ~D[2026-05-02], "pl") ==
               "30 kwietnia – 2 maja 2026"
    end

    test "links day, month and year with \"de\" in Portuguese" do
      assert LocaleFormat.format_date(~D[2026-04-05], "pt") == "5 de abril de 2026"

      assert LocaleFormat.format_date_range(~D[2026-04-10], ~D[2026-04-12], "pt") ==
               "10–12 de abril de 2026"

      assert LocaleFormat.format_date_range(~D[2026-04-30], ~D[2026-05-02], "pt") ==
               "30 de abril – 2 de maio de 2026"
    end

    test "links day, month and year with \"de\" in Spanish" do
      assert LocaleFormat.format_date_range(~D[2026-04-10], ~D[2026-04-12], "es") ==
               "10–12 de abril de 2026"

      assert LocaleFormat.format_date_range(~D[2026-04-30], ~D[2026-05-02], "es") ==
               "30 de abril – 2 de mayo de 2026"
    end

    test "keeps the period after the day in Czech" do
      assert LocaleFormat.format_date_range(~D[2026-04-10], ~D[2026-04-12], "cs") ==
               "10.–12. dubna 2026"
    end

    test "writes the first of a month as an ordinal at either end of the range" do
      assert LocaleFormat.format_date_range(~D[2026-10-01], ~D[2026-10-03], "fr") ==
               "1er–3 octobre 2026"

      assert LocaleFormat.format_date_range(~D[2026-09-30], ~D[2026-10-01], "it") ==
               "30 settembre – 1° ottobre 2026"

      assert LocaleFormat.format_date_range(~D[2026-10-01], ~D[2026-10-03], "pt") ==
               "1º–3 de outubro de 2026"

      assert LocaleFormat.format_date_range(~D[2026-09-30], ~D[2026-10-01], "pt") ==
               "30 de setembro – 1º de outubro de 2026"
    end

    test "keeps the first of a month a plain number elsewhere, with German's single stop" do
      assert LocaleFormat.format_date_range(~D[2026-10-01], ~D[2026-10-03], "en") ==
               "1–3 October 2026"

      assert LocaleFormat.format_date_range(~D[2026-09-30], ~D[2026-10-01], "de") ==
               "30. September – 1. Oktober 2026"
    end
  end

  describe "with_article/3" do
    test "elides the Italian article before the 8th and the 11th" do
      assert LocaleFormat.with_article("8 ottobre 2026", :da, "it") == "dall'8 ottobre 2026"
      assert LocaleFormat.with_article("11 marzo 2026", :none, "it") == "l'11 marzo 2026"
      assert LocaleFormat.with_article("8 ottobre", :a, "it") == "all'8 ottobre"
      assert LocaleFormat.with_article("11 marzo", :di, "it") == "dell'11 marzo"
      assert LocaleFormat.with_article("8 ottobre", :in, "it") == "nell'8 ottobre"
      assert LocaleFormat.with_article("11 marzo", :su, "it") == "sull'11 marzo"
    end

    test "keeps the full Italian article before every other day, the first included" do
      assert LocaleFormat.with_article("9 ottobre 2026", :da, "it") == "dal 9 ottobre 2026"
      assert LocaleFormat.with_article("1° ottobre 2026", :none, "it") == "il 1° ottobre 2026"
      assert LocaleFormat.with_article("18 ottobre", :a, "it") == "al 18 ottobre"
      assert LocaleFormat.with_article("28 ottobre", :di, "it") == "del 28 ottobre"
    end

    test "leaves the date unchanged in the other languages" do
      assert LocaleFormat.with_article("8 octobre 2026", :da, "fr") == "8 octobre 2026"
      assert LocaleFormat.with_article("11 March 2026", :none, "en") == "11 March 2026"
    end
  end

  describe "weekday and short dates" do
    test "write the first of a month as an ordinal in French, Italian and Portuguese" do
      assert LocaleFormat.format_weekday_date(~D[2026-10-01], "fr") == "jeudi 1er octobre 2026"
      assert LocaleFormat.format_short_date(~D[2026-10-01], "it") == "1° ott"
      assert LocaleFormat.format_short_date(~D[2026-10-01], "pt") == "1º de out"
      assert LocaleFormat.format_short_date(~D[2026-10-01], "de") == "1. Okt"
    end
  end

  describe "locale parameter edge cases" do
    test "handles nil locale gracefully" do
      date = ~D[2026-03-15]
      time = ~T[14:30:00]

      # Should fall back to English
      assert LocaleFormat.format_date(date, nil) == "15 March 2026"
      assert LocaleFormat.format_time(time, nil) == "02:30 PM"
    end

    test "handles empty string locale" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "") == "15 March 2026"
    end

    test "handles unusual but valid dates" do
      # Leap year
      leap_date = ~D[2024-02-29]
      assert LocaleFormat.format_date(leap_date, "en") == "29 February 2024"

      # New Year
      new_year = ~D[2026-01-01]
      assert LocaleFormat.format_date(new_year, "en") == "1 January 2026"

      # New Year's Eve
      nye = ~D[2026-12-31]
      assert LocaleFormat.format_date(nye, "en") == "31 December 2026"
    end
  end

  describe "format_month_year/3" do
    test "names the month in the nominative, not the in-date genitive" do
      assert LocaleFormat.format_month_year(1, 2026, "cs") == "Leden 2026"
      assert LocaleFormat.format_month_year(9, 2026, "uk") == "Вересень 2026"
      assert LocaleFormat.format_month_year(10, 2026, "pl") == "Październik 2026"
      assert LocaleFormat.format_month_year(10, 2026, "pt") == "Outubro de 2026"
      assert LocaleFormat.format_month_year(10, 2026, "es") == "Octubre de 2026"
    end

    test "capitalises the heading in languages that lowercase month names" do
      assert LocaleFormat.format_month_year(9, 2026, "fr") == "Septembre 2026"
      assert LocaleFormat.format_month_year(9, 2026, "it") == "Settembre 2026"
    end

    test "keeps English and German as they are" do
      assert LocaleFormat.format_month_year(9, 2026, "en") == "September 2026"
      assert LocaleFormat.format_month_year(3, 2026, "de") == "März 2026"
    end

    test "leaves the in-date month names untouched" do
      assert LocaleFormat.format_date(~D[2026-01-05], "cs") == "5. ledna 2026"
      assert LocaleFormat.format_date(~D[2026-09-05], "uk") == "5 вересня 2026"
    end
  end

  describe "format_standalone_month_name/2" do
    test "is lowercase where the language does not capitalise months" do
      assert LocaleFormat.format_standalone_month_name(10, "fr") == "octobre"
      assert LocaleFormat.format_standalone_month_name(10, "it") == "ottobre"
      assert LocaleFormat.format_standalone_month_name(10, "uk") == "жовтень"
      assert LocaleFormat.format_standalone_month_name(10, "cs") == "říjen"
      assert LocaleFormat.format_standalone_month_name(10, "pl") == "październik"
    end

    test "falls back to English for an unknown locale" do
      assert LocaleFormat.format_standalone_month_name(10, "xx") == "October"
    end
  end

  describe "capitalize_first/1" do
    test "upper-cases only the first letter, keeping later capitals and lowercase alike" do
      assert LocaleFormat.capitalize_first("září – říjen 2026") == "Září – říjen 2026"
      assert LocaleFormat.capitalize_first("Januar – Februar 2026") == "Januar – Februar 2026"
    end

    test "returns an empty string unchanged" do
      assert LocaleFormat.capitalize_first("") == ""
    end
  end
end
