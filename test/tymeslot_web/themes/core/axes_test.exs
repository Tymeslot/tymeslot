defmodule TymeslotWeb.Themes.Core.AxesTest do
  @moduledoc """
  The seven design axes a theme is described by: which values each takes,
  how a theme's declaration is checked, and how two themes are compared.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Core.Axes

  @quill [
    flow: :paged_wizard,
    entry: :meeting_type_first,
    spatial: :wide_card,
    time_view: :month_grid,
    conversion: :atmosphere,
    voice: :polished,
    surface: :glass
  ]

  describe "values/1" do
    test "offers every value the persona sections use on their axis" do
      assert :conversation in Axes.values(:flow)
      assert :questions_first in Axes.values(:entry)
      assert :split_card in Axes.values(:spatial)
      assert :next_slots in Axes.values(:time_view)
      assert :host_video in Axes.values(:conversion)
      assert :evocative in Axes.values(:voice)
      assert :soft_bubbles in Axes.values(:surface)
    end

    test "raises for an axis that does not exist" do
      assert_raise KeyError, fn -> Axes.values(:mood) end
    end
  end

  describe "validate!/1" do
    test "returns the axes in the canonical order, whatever order they came in" do
      assert Axes.validate!(Enum.reverse(@quill)) == @quill
      assert Keyword.keys(Axes.validate!(@quill)) == Axes.names()
    end

    test "refuses a missing axis, naming it" do
      assert_raise ArgumentError, ~r/missing.*:surface/, fn ->
        Axes.validate!(Keyword.delete(@quill, :surface))
      end
    end

    test "refuses an axis that does not exist, or one given twice" do
      assert_raise ArgumentError, ~r/repeated: \[:mood\]/, fn ->
        Axes.validate!(@quill ++ [mood: :calm])
      end

      assert_raise ArgumentError, ~r/repeated: \[:voice\]/, fn ->
        Axes.validate!(@quill ++ [voice: :warm])
      end
    end

    test "refuses a value outside its axis, naming both" do
      assert_raise ArgumentError, ~r/surface.*:glassy/, fn ->
        Axes.validate!(Keyword.put(@quill, :surface, :glassy))
      end
    end

    test "refuses anything but a literal keyword list" do
      assert_raise ArgumentError, ~r/keyword list/, fn -> Axes.validate!(:glass) end
    end
  end

  describe "differences/2" do
    test "names the axes two themes differ on, in the canonical order" do
      rhythm = Keyword.merge(@quill, spatial: :centred_card, time_view: :week_strip)

      assert Axes.differences(@quill, rhythm) == [:spatial, :time_view]
      assert Axes.differences(@quill, @quill) == []
    end
  end
end
