defmodule TymeslotWeb.Helpers.LocaleFormatNumbersTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Helpers.LocaleFormat

  # The space-grouping locales group with U+00A0, not a plain space, so a
  # figure cannot wrap mid-number. Spelled out here so an expectation that
  # merely looks right cannot pass against the wrong character.
  @nbsp "\u00A0"

  describe "format_integer/2" do
    test "groups thousands using each locale's separator" do
      assert LocaleFormat.format_integer(1500, "en") == "1,500"
      assert LocaleFormat.format_integer(1500, "de") == "1.500"
      assert LocaleFormat.format_integer(1500, "it") == "1.500"
      assert LocaleFormat.format_integer(1500, "cs") == "1#{@nbsp}500"
      assert LocaleFormat.format_integer(1500, "uk") == "1#{@nbsp}500"
      assert LocaleFormat.format_integer(1500, "fr") == "1#{@nbsp}500"
      assert LocaleFormat.format_integer(1500, "pl") == "1#{@nbsp}500"
      assert LocaleFormat.format_integer(1500, "es") == "1#{@nbsp}500"
    end

    test "leaves values below a thousand ungrouped" do
      assert LocaleFormat.format_integer(450, "cs") == "450"
      assert LocaleFormat.format_integer(999, "en") == "999"
      assert LocaleFormat.format_integer(0, "en") == "0"
    end

    test "groups every three places in longer numbers" do
      assert LocaleFormat.format_integer(450_000, "cs") == "450#{@nbsp}000"
      assert LocaleFormat.format_integer(1_234_567, "en") == "1,234,567"
    end

    test "keeps the sign outside the grouping" do
      # A sign left in the digit run would be chunked like a digit, misplacing
      # the separator whenever the digit count is a multiple of three.
      assert LocaleFormat.format_integer(-1234, "en") == "-1,234"
      assert LocaleFormat.format_integer(-123_456, "en") == "-123,456"
      assert LocaleFormat.format_integer(-1_234_567, "cs") == "-1#{@nbsp}234#{@nbsp}567"
    end
  end

  describe "group_separator/1" do
    test "reports the same separator format_integer/2 applies" do
      for locale <- ~w(en de it cs uk fr pl es) do
        separator = LocaleFormat.group_separator(locale)
        assert LocaleFormat.format_integer(1000, locale) == "1" <> separator <> "000"
      end
    end
  end

  describe "format_number/3 decimal places" do
    test "formats to two decimal places" do
      assert LocaleFormat.format_number(1234.5, "en", 2) == "1,234.50"
    end

    test "honours an explicit decimal count" do
      assert LocaleFormat.format_number(520.0, "en", 1) == "520.0"
      assert LocaleFormat.format_number(2080.0, "cs", 1) == "2#{@nbsp}080,0"
      assert LocaleFormat.format_number(2080.0, "pl", 1) == "2#{@nbsp}080,0"
      assert LocaleFormat.format_number(2080.0, "es", 1) == "2#{@nbsp}080,0"
    end

    test "omits the decimal separator entirely for zero decimals" do
      assert LocaleFormat.format_number(1234.5, "cs", 0) == "1#{@nbsp}235"
      assert LocaleFormat.format_number(999.4, "en", 0) == "999"
    end

    test "accepts integers as well as floats" do
      assert LocaleFormat.format_number(1500, "cs", 0) == "1#{@nbsp}500"
    end
  end
end
