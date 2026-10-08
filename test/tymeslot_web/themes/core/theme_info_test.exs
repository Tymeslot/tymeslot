defmodule TymeslotWeb.Themes.Core.ThemeInfoTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Test.FixtureTheme.Voice, as: FixtureVoice
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.Themes.Rhythm.Theme, as: Rhythm

  describe "get_theme_module/1" do
    test "is the theme's bound module, by string or integer id" do
      assert ThemeInfo.get_theme_module("1") == TymeslotWeb.Themes.Quill.Theme
      assert ThemeInfo.get_theme_module(2) == TymeslotWeb.Themes.Rhythm.Theme
    end

    test "is nil for an unknown id" do
      assert ThemeInfo.get_theme_module("no-such-theme") == nil
    end
  end

  describe "get_live_view_module/1" do
    test "is the theme's scheduling LiveView" do
      assert ThemeInfo.get_live_view_module("1") == TymeslotWeb.Themes.Quill.Scheduling.Live
    end

    test "is nil for an unknown id" do
      assert ThemeInfo.get_live_view_module("no-such-theme") == nil
    end
  end

  describe "get_voice/1" do
    test "is the voice the theme names, or nil" do
      assert ThemeInfo.get_voice("99") == FixtureVoice
      assert ThemeInfo.get_voice("1") == nil
      assert ThemeInfo.get_voice("no-such-theme") == nil
    end
  end

  describe "valid_theme_id?/1" do
    test "holds for every registered theme and for nothing else" do
      assert Enum.all?(Catalog.valid_ids(), &ThemeInfo.valid_theme_id?/1)
      refute ThemeInfo.valid_theme_id?("no-such-theme")
    end
  end

  describe "theme_options/0" do
    test "offers every active theme by name, in id order" do
      expected =
        Catalog.active()
        |> Map.values()
        |> Enum.sort_by(&String.to_integer(&1.id))
        |> Enum.map(&{&1.name, &1.id})

      assert ThemeInfo.theme_options() == expected
      assert [{"Quill", "1"}, {"Rhythm", "2"}] -- expected == []
    end
  end

  describe "theme_options/1" do
    test "hides beta themes, so one can ship before it is offered" do
      themes = %{
        quill: %{id: "1", name: "Quill", status: :active},
        next: %{id: "3", name: "Next", status: :beta}
      }

      assert ThemeInfo.theme_options(themes) == [{"Quill", "1"}]
    end

    test "sorts ids numerically, not as strings" do
      themes = %{
        ten: %{id: "10", name: "Ten", status: :active},
        two: %{id: "2", name: "Two", status: :active},
        one: %{id: "1", name: "One", status: :active}
      }

      assert ThemeInfo.theme_options(themes) == [{"One", "1"}, {"Two", "2"}, {"Ten", "10"}]
    end
  end

  describe "get_theme/1" do
    test "combines the catalogue facts with the theme's own metadata" do
      assert %{
               id: "2",
               key: :rhythm,
               name: "Rhythm",
               status: :active,
               preview_image: "/images/ui/theme-previews/rhythm-theme-preview.webp",
               description:
                 "Modern sliding design with video background and a 4-slide booking flow."
             } = ThemeInfo.get_theme("2")
    end

    test "carries the theme's story and axes" do
      assert %{
               story:
                 "When someone books me, I want them to feel the atmosphere first: motion, mood, then a time.",
               axes: [
                 flow: :paged_wizard,
                 entry: :meeting_type_first,
                 spatial: :centred_card,
                 time_view: :week_strip,
                 conversion: :atmosphere,
                 voice: :polished,
                 surface: :glass
               ]
             } = ThemeInfo.get_theme("2")
    end

    test "is nil for an unknown id" do
      assert ThemeInfo.get_theme("999") == nil
    end
  end

  describe "all_themes/0" do
    test "carries each theme's story and axes" do
      assert %{
               story: "My clients should feel they are booking someone established." <> _rest,
               axes: [
                 flow: :paged_wizard,
                 entry: :meeting_type_first,
                 spatial: :wide_card,
                 time_view: :month_grid,
                 conversion: :atmosphere,
                 voice: :polished,
                 surface: :glass
               ]
             } = Map.fetch!(ThemeInfo.all_themes(), "1")
    end
  end

  describe "metadata/0" do
    test "translates the description into the current locale" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")

      assert Rhythm.metadata().description ==
               Gettext.dgettext(
                 TymeslotWeb.Gettext,
                 "dashboard_appearance",
                 "Modern sliding design with video background and a 4-slide booking flow."
               )

      refute Rhythm.metadata().description =~ "Modern sliding design"
    end

    test "story/0 is translated into the current locale" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")

      refute Rhythm.story() =~ "When someone books me"
      assert Rhythm.story() =~ "Atmosphäre"
    end
  end
end
