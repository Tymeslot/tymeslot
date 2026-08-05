defmodule Tymeslot.Utils.DateTimeUtils.TimeFormatTest do
  @moduledoc """
  Covers the clock-format rules: how a format renders, which clock each language
  presets, and that a stored choice supersedes that preset.
  """

  use ExUnit.Case, async: true

  @moduletag :utils
  @moduletag :unit

  alias Tymeslot.Utils.DateTimeUtils.TimeFormat

  describe "format/2" do
    test "renders 12h as an unpadded hour with a meridiem" do
      assert TimeFormat.format(~T[14:30:00], "12h") == "2:30 PM"
    end

    test "renders 24h as a zero-padded 24-hour clock" do
      assert TimeFormat.format(~T[14:30:00], "24h") == "14:30"
    end

    test "renders midnight and noon unambiguously in 12h" do
      assert TimeFormat.format(~T[00:00:00], "12h") == "12:00 AM"
      assert TimeFormat.format(~T[12:00:00], "12h") == "12:00 PM"
    end

    test "renders midnight as 00:00 in 24h rather than 24:00" do
      assert TimeFormat.format(~T[00:00:00], "24h") == "00:00"
    end

    test "accepts DateTime and NaiveDateTime, not just Time" do
      assert TimeFormat.format(~U[2026-01-05 14:30:00Z], "12h") == "2:30 PM"
      assert TimeFormat.format(~N[2026-01-05 14:30:00], "24h") == "14:30"
    end

    test "treats an unrecognised or missing format as 24h rather than crashing" do
      # A hand-edited database row must degrade, not take a dashboard down.
      assert TimeFormat.format(~T[14:30:00], nil) == "14:30"
      assert TimeFormat.format(~T[14:30:00], "nonsense") == "14:30"
    end
  end

  describe "for_locale/1" do
    test "presets English to a 12-hour clock" do
      assert TimeFormat.for_locale("en") == "12h"
    end

    test "presets the 24-hour languages" do
      for locale <- ~w(de fr it uk) do
        assert TimeFormat.for_locale(locale) == "24h", "expected #{locale} to preset 24h"
      end
    end

    test "falls back to 12h for an unknown or missing locale" do
      assert TimeFormat.for_locale("es") == "12h"
      assert TimeFormat.for_locale(nil) == "12h"
    end
  end

  describe "resolve/2" do
    test "uses the language preset when nothing has been chosen" do
      assert TimeFormat.resolve(nil, "de") == "24h"
      assert TimeFormat.resolve(nil, "en") == "12h"
    end

    test "lets a stored choice supersede the language preset" do
      # The whole point of the setting: a German organiser who wants AM/PM
      # gets it, and an English one who wants 24h gets that.
      assert TimeFormat.resolve("12h", "de") == "12h"
      assert TimeFormat.resolve("24h", "en") == "24h"
    end

    test "falls back to the preset when the stored value is not a known format" do
      assert TimeFormat.resolve("", "de") == "24h"
      assert TimeFormat.resolve("nonsense", "en") == "12h"
    end
  end

  describe "valid?/1 and formats/0" do
    test "accepts exactly the two offered formats" do
      assert TimeFormat.formats() == ~w(12h 24h)
      assert TimeFormat.valid?("12h")
      assert TimeFormat.valid?("24h")
    end

    test "rejects anything else, including nil" do
      refute TimeFormat.valid?(nil)
      refute TimeFormat.valid?("12")
      refute TimeFormat.valid?(:"12h")
    end
  end
end
