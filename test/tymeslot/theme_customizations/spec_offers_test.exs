defmodule Tymeslot.ThemeCustomizations.SpecOffersTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.Test.ShowcaseThemeSpec
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.QuillSpec

  describe "spec_offers?/2" do
    test "is true for each option group the spec declares" do
      for option <- [:palette, :colour_mode, :cover] do
        assert ThemeCustomizations.spec_offers?(ShowcaseThemeSpec, option), inspect(option)
      end
    end

    test "is false for an option group the spec leaves out" do
      assert ThemeCustomizations.spec_offers?(QuillSpec, :palette)
      refute ThemeCustomizations.spec_offers?(QuillSpec, :colour_mode)
      refute ThemeCustomizations.spec_offers?(QuillSpec, :cover)
    end

    test "answers a background kind by the kinds the spec's background group lists" do
      for kind <- [:gradient, :color, :image, :video] do
        assert ThemeCustomizations.spec_offers?(QuillSpec, {:background, kind}), inspect(kind)
      end

      refute ThemeCustomizations.spec_offers?(QuillSpec, {:background, :pattern})
    end

    test "raises on an option it does not know" do
      assert_raise FunctionClauseError, fn ->
        ThemeCustomizations.spec_offers?(QuillSpec, :font)
      end
    end
  end
end
