defmodule Tymeslot.ThemeCustomizations.PaperSpecTest do
  @moduledoc """
  Paper's customisation: the shared groups it offers, in the canonical
  order, what each of them accepts, the tokens each colour mode gives the
  page, and what onboarding offers.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.CalendarView
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Logo
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias Tymeslot.ThemeCustomizations.PaperSpec
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.Utils.Colour
  alias TymeslotWeb.Themes.Shared.ThemeStyle

  defp defaults,
    do: Map.new(PaperSpec.defaults(), fn {key, value} -> {Atom.to_string(key), value} end)

  defp validate(attrs) do
    {%{}, Specs.setting_types(PaperSpec)}
    |> Changeset.change()
    |> PaperSpec.changeset(attrs)
  end

  defp tokens(changes, overrides \\ %{}),
    do: PaperSpec.tokens(Map.merge(defaults(), changes), overrides)

  describe "option groups" do
    test "are the shared groups Paper offers, in the canonical order" do
      assert Enum.map(PaperSpec.option_groups(), & &1.module) ==
               [Palette, ColourMode, Font, Radius, CalendarView, Logo]
    end

    test "offer the eight palettes, following the visitor's OS, and no background" do
      palette = Specs.group(PaperSpec, Palette)

      assert palette.schemes ==
               ~w(paper_turquoise paper_arctic paper_purple paper_sunset paper_ocean paper_forest paper_rose paper_monochrome)

      for {_id, scheme} <- Palette.schemes(palette) do
        assert %{mode: :light, dark_colors: %{}} = scheme
      end

      assert palette.follow_os == true
      assert palette.seed_mode == :light
      assert Specs.background_kinds(PaperSpec) == []
    end

    test "offer three fonts" do
      assert Specs.group(PaperSpec, Font).presets == ~w(system inter plex)
    end

    test "store one upload, the logo" do
      assert PaperSpec.asset_fields() == [{:logo_path, :image}]
    end

    test "store no density and no background" do
      types = Specs.setting_types(PaperSpec)

      refute Map.has_key?(types, :density)
      refute Map.has_key?(types, :background_type)
    end
  end

  describe "the generated changeset" do
    test "accepts the defaults" do
      assert validate(defaults()).valid?
    end

    for {setting, value} <- [
          {"color_scheme", "neutral"},
          {"colour_mode", "sepia"},
          {"font", "editorial"},
          {"radius", "pill"},
          {"calendar_view", "day"}
        ] do
      test "refuses #{setting} #{inspect(value)}, which Paper does not offer" do
        changeset = validate(Map.put(defaults(), unquote(setting), unquote(value)))

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, String.to_existing_atom(unquote(setting)))
      end
    end

    test "accepts the week calendar view" do
      assert validate(Map.put(defaults(), "calendar_view", "week")).valid?
    end

    test "accepts a custom seed colour in place of a palette" do
      assert validate(Map.put(defaults(), "custom_palette_seed", "#7c2d12")).valid?
    end
  end

  describe "tokens" do
    test "auto, the default, shows the turquoise light set and the dark set inside the dark media query" do
      tokens = tokens(%{})

      assert tokens.vars["--theme-canvas"] == "#ecfeff"
      assert tokens.vars["--theme-surface"] == "#ffffff"
      assert tokens.vars["--theme-primary"] == "#0e7490"
      assert tokens.vars["--theme-color-scheme"] == "light dark"
      assert tokens.dark_vars["--theme-canvas"] == "#0f172a"
      assert tokens.dark_vars["--theme-primary"] == "#22d3ee"
      assert ThemeStyle.css(tokens) =~ "@media (prefers-color-scheme: dark)"
    end

    test "light writes no dark block" do
      tokens = tokens(%{"colour_mode" => "light"})

      assert tokens.vars["--theme-color-scheme"] == "light"
      assert tokens.dark_vars == %{}
      refute ThemeStyle.css(tokens) =~ "prefers-color-scheme"
    end

    test "dark puts the palette's dark set on the page" do
      tokens = tokens(%{"color_scheme" => "paper_forest", "colour_mode" => "dark"})

      assert tokens.vars["--theme-canvas"] == "#052e16"
      assert tokens.vars["--theme-surface"] == "#0f3d22"
      assert tokens.vars["--theme-primary"] == "#34d399"
      assert tokens.vars["--theme-color-scheme"] == "dark"
      assert tokens.dark_vars == %{}
    end

    test "a custom seed derives both sets from one colour" do
      tokens = tokens(%{"custom_palette_seed" => "#7c3aed"})

      assert tokens.vars["--theme-canvas"]
      assert tokens.dark_vars["--theme-canvas"]
      refute tokens.vars["--theme-canvas"] == tokens.dark_vars["--theme-canvas"]
    end

    test "an embed's primary colour wins over the palette's, in both sets" do
      tokens = tokens(%{}, %{primary_color: "#e11d48"})

      assert tokens.vars["--theme-primary"] == "#e11d48"
      # Too dark to read on the dark card, so lightened in the same hue.
      assert tokens.dark_vars["--theme-primary"] == "#eb6582"
    end

    test "an embed's pale primary colour is fitted to read as text on the card, in both sets" do
      tokens = tokens(%{}, %{primary_color: "#ffff00"})

      for vars <- [tokens.vars, tokens.dark_vars] do
        assert Colour.contrast_ratio(vars["--theme-primary"], vars["--theme-surface"]) >= 4.5
      end
    end

    test "the font and the corners are the chosen ones" do
      vars = tokens(%{"font" => "plex", "radius" => "round"}).vars

      assert vars["--theme-font-family"] == "var(--font-stack-plex)"
      assert vars["--theme-font-heading"] == "var(--font-heading-plex)"
      assert vars["--radius-control"] == "999px"
      assert vars["--radius-card"] == "20px"
    end

    test "the calendar view is a month until the week is chosen" do
      assert tokens(%{}).media[:calendar_view] == "month"
      assert tokens(%{"calendar_view" => "week"}).media[:calendar_view] == "week"
    end

    test "never set a density" do
      refute Map.has_key?(tokens(%{}).vars, "--density")
    end

    test "an uploaded logo is the page's logo; without one there is none" do
      assert tokens(%{"logo_path" => "themes/7/3/images/logo.png"}).media[:logo] ==
               %{src: "/uploads/themes/7/3/images/logo.png"}

      refute Map.has_key?(tokens(%{}).media, :logo)
    end
  end

  describe "onboarding" do
    test "offers the eight palettes, in the group's order, swatched by their primary" do
      assert %{group: :palette, field: "scheme", setting: "color_scheme", choices: choices} =
               PaperSpec.onboarding_choices()

      assert Enum.map(choices, & &1.value) == Specs.group(PaperSpec, Palette).schemes

      assert %{name: "Forest Green", swatch: "#047857"} =
               Enum.find(choices, &(&1.value == "paper_forest"))
    end

    test "every choice is one the palette group saves" do
      group = Specs.group(PaperSpec, Palette)

      for %{value: value} <- PaperSpec.onboarding_choices().choices do
        assert {:ok, changes} = Palette.changes("scheme", value, group)
        assert validate(Map.merge(defaults(), changes)).valid?
      end
    end
  end
end
