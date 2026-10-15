defmodule TymeslotWeb.Helpers.LocaleFormatDateShapesTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Helpers.LocaleFormat

  describe "weekday and short date shapes" do
    # 2026-02-05 is a Thursday.
    @date ~D[2026-02-05]

    for {locale, weekday_date, weekday_day_month, short, short_weekday} <- [
          {"en", "Thursday, 5 February 2026", "Thursday, 5 February", "5 Feb", "Thu 5 Feb"},
          {"de", "Donnerstag, 5. Februar 2026", "Donnerstag, 5. Februar", "5. Feb", "Do 5. Feb"},
          {"fr", "jeudi 5 février 2026", "jeudi 5 février", "5 févr.", "jeu 5 févr."},
          {"it", "giovedì 5 febbraio 2026", "giovedì 5 febbraio", "5 feb", "gio 5 feb"},
          {"cs", "čtvrtek 5. února 2026", "čtvrtek 5. února", "5. úno", "čt 5. úno"},
          {"uk", "Четвер, 5 лютого 2026", "Четвер, 5 лютого", "5 лют", "Чт 5 лют"},
          {"pl", "czwartek, 5 lutego 2026", "czwartek, 5 lutego", "5 lut", "czw 5 lut"}
        ] do
      test "#{locale}: orders the date parts the way the language writes them" do
        locale = unquote(locale)

        assert LocaleFormat.format_weekday_date(@date, locale) == unquote(weekday_date)
        assert LocaleFormat.format_weekday_day_month(@date, locale) == unquote(weekday_day_month)
        assert LocaleFormat.format_short_date(@date, locale) == unquote(short)
        assert LocaleFormat.format_short_weekday_date(@date, locale) == unquote(short_weekday)
      end
    end

    test "pt: links day, month and year with \"de\"" do
      assert LocaleFormat.format_weekday_date(@date, "pt") ==
               "quinta-feira, 5 de fevereiro de 2026"

      assert LocaleFormat.format_weekday_day_month(@date, "pt") == "quinta-feira, 5 de fevereiro"

      assert LocaleFormat.format_short_date(@date, "pt") == "5 de fev"
      assert LocaleFormat.format_short_weekday_date(@date, "pt") == "qui 5 de fev"
    end

    test "an unknown locale falls back to English order" do
      assert LocaleFormat.format_weekday_date(@date, "xx") == "Thursday, 5 February 2026"
    end
  end

  describe "format_short_date_with_year/2" do
    for {locale, expected} <- [
          {"en", "5 Feb 2026"},
          {"de", "5. Feb 2026"},
          {"fr", "5 févr. 2026"},
          {"cs", "5. úno 2026"},
          {"pl", "5 lut 2026"},
          {"pt", "5 de fev de 2026"}
        ] do
      test "#{locale}: adds the year in the locale's order" do
        assert LocaleFormat.format_short_date_with_year(~D[2026-02-05], unquote(locale)) ==
                 unquote(expected)
      end
    end
  end

  describe "format_weekday_datetime/2" do
    # 2026-02-05 is a Thursday.
    @datetime ~U[2026-02-05 14:30:00Z]

    for {locale, expected} <- [
          {"en", "Thursday, 5 February 2026 · 02:30 PM"},
          {"de", "Donnerstag, 5. Februar 2026 · 14:30"},
          {"fr", "jeudi 5 février 2026 · 14:30"},
          {"cs", "čtvrtek 5. února 2026 · 14:30"},
          {"pt", "quinta-feira, 5 de fevereiro de 2026 · 14:30"}
        ] do
      test "#{locale}: sets the weekday-led date beside the locale's clock" do
        assert LocaleFormat.format_weekday_datetime(@datetime, unquote(locale)) ==
                 unquote(expected)
      end
    end
  end
end
