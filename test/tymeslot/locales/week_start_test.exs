defmodule Tymeslot.Locales.WeekStartTest do
  use ExUnit.Case, async: true

  @moduletag :i18n
  @moduletag :unit

  alias Tymeslot.Locales.WeekStart

  doctest WeekStart

  describe "from_language_tags/1" do
    test "a Sunday-first region decides, whatever the language" do
      assert WeekStart.from_language_tags(["en-US"]) == :sunday
      assert WeekStart.from_language_tags(["fr-CA"]) == :sunday
      assert WeekStart.from_language_tags(["pt-BR"]) == :sunday
    end

    test "any other region is Monday, including Saturday-first ones" do
      assert WeekStart.from_language_tags(["en-GB"]) == :monday
      assert WeekStart.from_language_tags(["es-ES"]) == :monday
      assert WeekStart.from_language_tags(["ar-EG"]) == :monday
    end

    test "a region is read past script subtags and in any case or separator" do
      assert WeekStart.from_language_tags(["zh-Hant-TW"]) == :sunday
      assert WeekStart.from_language_tags(["EN_us"]) == :sunday
    end

    test "only tags in the top tag's language lend it a region" do
      assert WeekStart.from_language_tags(["en", "en-US"]) == :sunday
      assert WeekStart.from_language_tags(["de", "en-US"]) == :monday
      assert WeekStart.from_language_tags(["en", "de-DE"]) == nil
    end

    test "a bare language settles it when its speakers agree" do
      assert WeekStart.from_language_tags(["pl"]) == :monday
      assert WeekStart.from_language_tags(["pt"]) == :sunday
      assert WeekStart.from_language_tags(["ja"]) == :sunday
    end

    test "a bare language spoken on both sides leaves it open" do
      for language <- ~w(en es ar zh) do
        assert WeekStart.from_language_tags([language]) == nil
      end
    end

    test "no usable tag leaves it open" do
      assert WeekStart.from_language_tags([]) == nil
      assert WeekStart.from_language_tags(["*"]) == nil
      assert WeekStart.from_language_tags(["not a tag"]) == nil
    end
  end

  test "parse/1 reads a stored setting, defaulting to Monday" do
    assert WeekStart.parse("sunday") == :sunday
    assert WeekStart.parse("monday") == :monday
    assert WeekStart.parse(nil) == :monday
  end
end
