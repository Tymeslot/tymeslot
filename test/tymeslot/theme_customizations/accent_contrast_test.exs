defmodule Tymeslot.ThemeCustomizations.AccentContrastTest do
  @moduledoc """
  The accent contrast rule, over the accent preset table and random custom
  colours: in every colour set a page can show, the accent reads as text on
  the card and the filled control's ink reads on both stops of its fill, at
  WCAG AA (4.5:1).

  The card is the set's surface, or its canvas where the surface is
  translucent (a dark seed derivation's), which is what `Options.Accent`
  fits against.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.Test.ThemeCustomizations.GroupsSpec
  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.Utils.Colour

  @aa 4.5

  # Seeds of the light palettes the accent sits on: warm, dark, bright, cyan,
  # grey and violet.
  @seeds ~w(#b4532a #123456 #ffff00 #22d3ee #808080 #7c3aed)

  defp accents, do: Specs.group(GroupsSpec, Accent).presets

  defp card(vars),
    do: Enum.find([vars["--theme-surface"], vars["--theme-canvas"]], &Colour.parse_hex/1)

  defp with_seed(seed, accent),
    do: %{"color_scheme" => "custom", "custom_palette_seed" => seed, "accent" => accent}

  # Every colour set the page can show: the page's, and the dark one.
  defp sets(settings, overrides \\ %{}) do
    tokens = GroupsSpec.tokens(settings, overrides)
    Enum.reject([tokens.vars, tokens.dark_vars], &(&1 == %{}))
  end

  defp failing_pairs(vars) do
    for {pair, ink, ground} <- [
          {:primary_on_card, vars["--theme-primary"], card(vars)},
          {:on_primary_solid, vars["--theme-on-primary"], vars["--theme-primary-solid"]},
          {:on_primary_solid_hover, vars["--theme-on-primary"],
           vars["--theme-primary-solid-hover"]}
        ],
        Colour.contrast_ratio(ink, ground) < @aa,
        do: pair
  end

  defp to_hex(rgb), do: "#" <> String.pad_leading(Integer.to_string(rgb, 16), 6, "0")

  test "every accent preset clears AA as text and as a filled control, on every palette" do
    assert length(accents()) == 9

    failures =
      for seed <- @seeds,
          accent <- accents(),
          vars <- sets(with_seed(seed, accent)),
          bad = failing_pairs(vars),
          bad != [],
          do: {seed, accent, bad}

    assert failures == []
  end

  defp toned(tone, mode, accent),
    do: %{"color_scheme" => tone, "colour_mode" => mode, "accent" => accent}

  defp tones, do: Specs.group(GroupsSpec, Palette).schemes

  test "every accent preset clears AA on every tone, in every colour mode" do
    assert tones() == ~w(neutral cool warm)
    assert ColourMode.modes() == ~w(light dark auto)

    failures =
      for tone <- tones(),
          mode <- ColourMode.modes(),
          accent <- accents(),
          vars <- sets(toned(tone, mode, accent)),
          bad = failing_pairs(vars),
          bad != [],
          do: {tone, mode, accent, bad}

    assert failures == []
  end

  test "graphite, the no-colour choice, turns to a light grey on a dark card" do
    [dark] = sets(toned("neutral", "dark", "graphite"))

    assert dark["--theme-primary"] == "#7586a2"
  end

  property "any custom accent, and any embed's primary colour, on any tone in any mode" do
    check all(
            rgb <- StreamData.integer(0..0xFFFFFF),
            tone <- StreamData.member_of(~w(neutral cool warm)),
            mode <- StreamData.member_of(~w(light dark auto)),
            max_runs: 200
          ) do
      hex = to_hex(rgb)

      for vars <-
            sets(toned(tone, mode, hex)) ++
              sets(toned(tone, mode, "tymeslot"), %{primary_color: hex}) do
        assert failing_pairs(vars) == []
      end
    end
  end

  test "every palette here has a dark set, so both modes are checked" do
    assert Enum.reject(@seeds, &(length(sets(with_seed(&1, "tymeslot"))) == 2)) == []
  end

  property "so does any custom accent, and any embed's primary colour" do
    check all(
            rgb <- StreamData.integer(0..0xFFFFFF),
            seed <- StreamData.member_of(@seeds),
            max_runs: 200
          ) do
      hex = to_hex(rgb)

      for vars <-
            sets(with_seed(seed, hex)) ++ sets(with_seed(seed, "tymeslot"), %{primary_color: hex}) do
        assert failing_pairs(vars) == []
      end
    end
  end
end
