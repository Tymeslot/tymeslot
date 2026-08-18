defmodule Tymeslot.Integrations.Calendar.EventColourTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.EventColour

  describe "palette/0 and keys/0" do
    test "exposes a fixed, non-empty palette of {key, label, class} tuples" do
      palette = EventColour.palette()

      assert length(palette) == 8

      Enum.each(palette, fn entry ->
        assert {key, label, class} = entry
        assert key in EventColour.keys()
        assert label == EventColour.label(key)
        assert class == "bg-calendar-#{key}"
      end)
    end

    test "labels follow the caller's locale" do
      # The swatches carry no visible text, so the label is the whole
      # accessible name of the control — it cannot stay English.
      assert EventColour.label("blueberry") == "Blueberry"

      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert EventColour.label("blueberry") == "Blaubeere"

        assert {"blueberry", "Blaubeere", _class} =
                 Enum.find(EventColour.palette(), &(elem(&1, 0) == "blueberry"))
      end)
    end

    test "keys/0 lists every palette key" do
      assert EventColour.keys() == [
               "tomato",
               "tangerine",
               "banana",
               "sage",
               "peacock",
               "blueberry",
               "grape",
               "graphite"
             ]
    end
  end

  describe "valid_key?/1" do
    test "is true for palette keys" do
      assert EventColour.valid_key?("tomato")
      assert EventColour.valid_key?("graphite")
    end

    test "is false for unknown values and non-strings" do
      refute EventColour.valid_key?("1")
      refute EventColour.valid_key?("not-a-colour")
      refute EventColour.valid_key?(nil)
      refute EventColour.valid_key?(11)
    end
  end

  describe "rotation_class/1 and rotation_size/0" do
    test "returns a distinct class for every index in the rotation" do
      classes = Enum.map(1..EventColour.rotation_size(), &EventColour.rotation_class/1)

      assert length(Enum.uniq(classes)) == EventColour.rotation_size()
      assert Enum.all?(classes, &String.starts_with?(&1, "bg-calendar-"))
    end

    test "falls back to the neutral class for an index outside the rotation" do
      assert EventColour.rotation_class(EventColour.rotation_size() + 1) ==
               EventColour.fallback_class()

      assert EventColour.rotation_class(0) == EventColour.fallback_class()
      assert EventColour.rotation_class(-1) == EventColour.fallback_class()
      assert EventColour.rotation_class(nil) == EventColour.fallback_class()
      assert EventColour.rotation_class("2") == EventColour.fallback_class()
    end
  end

  describe "tailwind_class/1" do
    test "maps a palette key to its own Tailwind class" do
      assert EventColour.tailwind_class("tomato") == "bg-calendar-tomato"
      assert EventColour.tailwind_class("blueberry") == "bg-calendar-blueberry"
    end

    test "no palette key borrows a class from the rotation" do
      # The two sets are separate on purpose: a palette class has to look like
      # the name it is labelled with, a rotation class only has to differ from
      # its neighbours. Sharing one would tie the two constraints together.
      rotation = Enum.map(1..EventColour.rotation_size(), &EventColour.rotation_class/1)
      palette = Enum.map(EventColour.palette(), fn {_key, _label, class} -> class end)

      assert palette -- rotation == palette
    end

    test "every palette entry maps to a distinct Tailwind class" do
      classes = Enum.map(EventColour.palette(), fn {_key, _label, class} -> class end)

      assert Enum.uniq(classes) == classes
    end

    test "tangerine and banana render as distinct, non-fallback colours" do
      tangerine_class = EventColour.tailwind_class("tangerine")
      banana_class = EventColour.tailwind_class("banana")

      assert tangerine_class != banana_class
      refute tangerine_class == "bg-calendar-fallback"
      refute banana_class == "bg-calendar-fallback"
    end

    test "returns nil for nil so callers fall back to integration colour" do
      assert EventColour.tailwind_class(nil) == nil
    end

    test "returns the neutral fallback for unknown values (e.g. raw provider colour)" do
      # Inbound Google stores raw colorId strings like "1".."11" which are not
      # palette keys — must not crash, falls back gracefully.
      assert EventColour.tailwind_class("11") == "bg-calendar-fallback"
      assert EventColour.tailwind_class("unknown") == "bg-calendar-fallback"
    end
  end

  describe "google_color_id/1" do
    test "maps palette keys to Google colorIds" do
      assert EventColour.google_color_id("tomato") == "11"
      assert EventColour.google_color_id("sage") == "2"
      assert EventColour.google_color_id("graphite") == "8"
    end

    test "returns nil for unknown keys so the mapper omits colorId" do
      assert EventColour.google_color_id("11") == nil
      assert EventColour.google_color_id(nil) == nil
    end
  end

  describe "css_colour/1" do
    test "maps palette keys to CSS3 colour names" do
      assert EventColour.css_colour("tomato") == "tomato"
      assert EventColour.css_colour("peacock") == "teal"
      assert EventColour.css_colour("grape") == "darkorchid"
    end

    test "returns nil for unknown keys so the builder omits the COLOR line" do
      assert EventColour.css_colour("not-a-key") == nil
      assert EventColour.css_colour(nil) == nil
    end
  end

  describe "from_google_color_id/1" do
    test "maps a known Google colorId to its palette key" do
      assert EventColour.from_google_color_id("9") == "blueberry"
      assert EventColour.from_google_color_id("11") == "tomato"
      assert EventColour.from_google_color_id("3") == "grape"
    end

    test "returns nil for unknown or nil colorId" do
      assert EventColour.from_google_color_id("999") == nil
      assert EventColour.from_google_color_id(nil) == nil
      assert EventColour.from_google_color_id(42) == nil
    end

    test "snaps Google colorIds without an exact palette match to the nearest key" do
      assert EventColour.from_google_color_id("1") == "graphite"
      assert EventColour.from_google_color_id("4") == "tomato"
      assert EventColour.from_google_color_id("10") == "peacock"
    end
  end

  describe "nearest_key/1" do
    test "snaps an exact palette hex to its key" do
      assert EventColour.nearest_key("#4169E1") == "blueberry"
      assert EventColour.nearest_key("#FF6347") == "tomato"
    end

    test "snaps a near hex to the closest key" do
      assert EventColour.nearest_key("#4269E2") == "blueberry"
    end

    test "accepts a known CSS colour name" do
      assert EventColour.nearest_key("royalblue") == "blueberry"
      assert EventColour.nearest_key("teal") == "peacock"
    end

    test "accepts a wider set of CSS3 colour names (RFC 7986 CalDAV COLOR)" do
      assert EventColour.nearest_key("crimson") == "tomato"
      assert EventColour.nearest_key("navy") == "peacock"
      assert EventColour.nearest_key("olive") == "sage"
      assert EventColour.nearest_key("cornflowerblue") == "blueberry"
    end

    test "ignores an alpha channel (#RRGGBBAA)" do
      assert EventColour.nearest_key("#4169E1FF") == "blueberry"
    end

    test "returns nil when the alpha pair itself is not valid hex" do
      assert EventColour.nearest_key("#4169E1ZZ") == nil
    end

    test "expands 3-digit shorthand hex before snapping" do
      assert EventColour.nearest_key("#f00") == "tomato"
      assert EventColour.nearest_key("#F00") == "tomato"
    end

    test "returns nil for nil or unparseable input" do
      assert EventColour.nearest_key(nil) == nil
      assert EventColour.nearest_key("not-a-colour") == nil
      assert EventColour.nearest_key(123) == nil
    end
  end
end
