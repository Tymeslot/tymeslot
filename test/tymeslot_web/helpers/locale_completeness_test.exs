defmodule TymeslotWeb.Helpers.LocaleCompletenessTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Helpers.LocaleFormat

  @supported_locales Enum.map(Application.compile_env(:tymeslot, :locales)[:supported], & &1.code)

  for locale <- @supported_locales do
    describe "#{locale} locale completeness" do
      test "has 12 month names" do
        months = LocaleFormat.get_month_names(unquote(locale))

        assert length(months) == 12,
               "Expected 12 month names for #{unquote(locale)}, got #{length(months)}"
      end

      if locale != "en" do
        test "month names differ from English" do
          en_months = LocaleFormat.get_month_names("en")
          locale_months = LocaleFormat.get_month_names(unquote(locale))

          assert locale_months != en_months,
                 "#{unquote(locale)} month names should not fall through to English"
        end
      end

      test "has 7 full weekday names" do
        weekdays = LocaleFormat.get_weekday_names(unquote(locale), :full)
        assert length(weekdays) == 7, "Expected 7 full weekday names for #{unquote(locale)}"
      end

      test "has 7 short weekday names" do
        weekdays = LocaleFormat.get_weekday_names(unquote(locale), :short)
        assert length(weekdays) == 7, "Expected 7 short weekday names for #{unquote(locale)}"
      end

      test "has 7 narrow weekday names" do
        weekdays = LocaleFormat.get_weekday_names(unquote(locale), :narrow)
        assert length(weekdays) == 7, "Expected 7 narrow weekday names for #{unquote(locale)}"
      end

      if locale != "en" do
        test "date format differs from English fallback" do
          date = ~D[2026-03-15]
          en_format = LocaleFormat.format_date(date, "en")
          locale_format = LocaleFormat.format_date(date, unquote(locale))

          assert locale_format != en_format,
                 "#{unquote(locale)} date format should differ from English"
        end
      end

      test "time format produces a valid string" do
        time = ~T[14:30:00]
        result = LocaleFormat.format_time(time, unquote(locale))

        assert is_binary(result) and result != "",
               "#{unquote(locale)} time format should produce a non-empty string"
      end

      test "number formatting uses locale-appropriate separators" do
        result = LocaleFormat.format_number(1234.56, unquote(locale))
        assert is_binary(result), "#{unquote(locale)} number formatting should produce a string"

        case unquote(locale) do
          "en" ->
            assert result =~ ",", "English should use comma as thousand separator"
            assert result =~ ".", "English should use period as decimal separator"

          "de" ->
            assert result =~ ".", "German should use period as thousand separator"
            assert result =~ ",", "German should use comma as decimal separator"

          "it" ->
            assert result =~ ".", "Italian should use period as thousand separator"
            assert result =~ ",", "Italian should use comma as decimal separator"

          "uk" ->
            assert result =~ " ", "Ukrainian should use space as thousand separator"
            assert result =~ ",", "Ukrainian should use comma as decimal separator"

          "fr" ->
            assert result =~ " ", "French should use space as thousand separator"
            assert result =~ ",", "French should use comma as decimal separator"
        end
      end

      test "Gettext PO file exists" do
        po_path =
          Path.join([
            :code.priv_dir(:tymeslot),
            "gettext",
            unquote(locale),
            "LC_MESSAGES",
            "default.po"
          ])

        assert File.exists?(po_path),
               "Missing Gettext PO file for #{unquote(locale)} at #{po_path}"
      end

      test "emails Gettext PO file exists" do
        po_path =
          Path.join([
            :code.priv_dir(:tymeslot),
            "gettext",
            unquote(locale),
            "LC_MESSAGES",
            "emails.po"
          ])

        assert File.exists?(po_path),
               "Missing emails Gettext PO file for #{unquote(locale)} at #{po_path}"
      end
    end
  end
end
