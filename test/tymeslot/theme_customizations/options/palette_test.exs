defmodule Tymeslot.ThemeCustomizations.Options.PaletteTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.Utils.Colour

  @group %{key: :palette, module: Palette, schemes: ~w(default forest ocean purple)}
  @follow_os Map.put(@group, :follow_os, true)
  @light_seed Map.put(@group, :seed_mode, :light)

  # No light scheme ships yet (Paper brings the first); this one stands in.
  @light_scheme %{
    name: "Test Ivory",
    mode: :light,
    colors: %{
      primary: "#b4532a",
      primary_hover: "#9a4524",
      secondary: "#6b5a4a",
      accent: "#4d7c5a",
      background: "#faf7f2",
      surface: "#ffffff",
      text: "#1f1b16",
      text_secondary: "#5c5347"
    },
    dark_colors: %{
      primary: "#e0875c",
      primary_hover: "#d4703f",
      secondary: "#b8a898",
      accent: "#8fbf9c",
      background: "#1b1a24",
      surface: "rgba(40, 38, 52, 0.6)",
      text: "#ece8f4",
      text_secondary: "#b9b3c6"
    }
  }

  defp filled_pair_clears_aa?(vars),
    do: Colour.contrast_ratio(vars["--theme-on-primary"], vars["--theme-primary-solid"]) >= 4.5

  defp changeset(attrs, group \\ @group) do
    {%{}, Palette.types()}
    |> Changeset.change()
    |> Palette.changeset(attrs, group)
  end

  describe "changeset/3" do
    test "normalises a custom seed to lower-case #rrggbb, three-digit form included" do
      assert Changeset.get_change(
               changeset(%{"custom_palette_seed" => "#FA0"}),
               :custom_palette_seed
             ) ==
               "#ffaa00"
    end

    test "rejects a seed that is not a hex colour" do
      cs = changeset(%{"custom_palette_seed" => "not-hex"})

      refute cs.valid?
      assert {"must be a valid hex colour", _opts} = cs.errors[:custom_palette_seed]
    end

    test "rejects an unknown preset scheme when no seed is set" do
      cs = changeset(%{"color_scheme" => "neon"})

      refute cs.valid?
      assert {"is invalid", _opts} = cs.errors[:color_scheme]
    end

    test "rejects a shipped scheme the group does not list" do
      cs = changeset(%{"color_scheme" => "rose"})

      refute cs.valid?
      assert {"is invalid", _opts} = cs.errors[:color_scheme]
    end

    test "does not constrain the scheme name while a seed drives the palette" do
      assert changeset(%{"color_scheme" => "neon", "custom_palette_seed" => "#ff6b35"}).valid?
    end
  end

  describe "changes/3" do
    test "a scheme drops the custom seed" do
      assert Palette.changes("scheme", "forest", @group) ==
               {:ok, %{"color_scheme" => "forest", "custom_palette_seed" => nil}}
    end

    test "a seed leaves the scheme name alone" do
      assert Palette.changes("seed", "#aabbcc", @group) ==
               {:ok, %{"custom_palette_seed" => "#aabbcc"}}
    end

    test "a blank seed casts to nil and switches back to the preset scheme" do
      assert {:ok, %{"custom_palette_seed" => ""}} = Palette.changes("seed", "", @group)

      cs = changeset(%{"color_scheme" => "forest", "custom_palette_seed" => ""})

      assert Changeset.get_change(cs, :custom_palette_seed) == nil
      assert cs.valid?
    end

    test "any other field is refused" do
      assert Palette.changes("logo", "x.png", @group) == :error
    end
  end

  describe "schemes/1" do
    test "the group's schemes, in the group's order" do
      assert [{"ocean", %{name: "Ocean Breeze"}}, {"forest", %{name: "Forest Green"}}] =
               Palette.schemes(%{@group | schemes: ["ocean", "forest"]})
    end
  end

  describe "resolve/2" do
    test "derives the palette from a stored seed" do
      assert %{name: "Custom", colors: %{primary: "#ff6b35"}} =
               Palette.resolve(
                 %{"color_scheme" => "purple", "custom_palette_seed" => "#ff6b35"},
                 @group
               )
    end

    test "is the named preset when no seed is stored" do
      assert %{name: "Purple Dream", colors: %{primary: "#8b5cf6"}} =
               Palette.resolve(
                 %{"color_scheme" => "purple", "custom_palette_seed" => nil},
                 @group
               )
    end

    test "is nil for an unknown scheme and no seed" do
      assert Palette.resolve(
               %{"color_scheme" => "nonexistent", "custom_palette_seed" => nil},
               @group
             ) == nil
    end

    test "derives a seed in the group's seed_mode" do
      settings = %{"color_scheme" => "purple", "custom_palette_seed" => "#ff6b35"}

      assert %{mode: :dark} = Palette.resolve(settings, @group)

      assert Palette.resolve(settings, @light_seed) ==
               PaletteDerivation.derive_palette("#ff6b35", :light)
    end
  end

  describe "tokens/3" do
    test "emits the preset's colours and its contrast pairs as --theme-* properties" do
      %{vars: vars} =
        Palette.tokens(%{"color_scheme" => "purple", "custom_palette_seed" => nil}, %{}, @group)

      assert vars["--theme-primary"] == "#8b5cf6"
      assert vars["--theme-text-secondary"] == "#c4b5fd"
      assert vars["--theme-on-primary"] == "#ffffff"
      assert vars["--theme-primary-solid"] == "#8452f5"
    end

    test "emits the palette's background as --theme-canvas, never --theme-background" do
      %{vars: vars} = Palette.tokens(%{"color_scheme" => "purple"}, %{}, @group)

      assert vars["--theme-canvas"] == "#1e1b4b"
      refute Map.has_key?(vars, "--theme-background")
    end

    test "derives the palette from the seed when one is stored" do
      %{vars: vars} =
        Palette.tokens(
          %{"color_scheme" => "purple", "custom_palette_seed" => "#ff6b35"},
          %{},
          @group
        )

      assert vars["--theme-primary"] == "#ff6b35"
    end

    test "derives the palette from a seed stored without a scheme name" do
      %{vars: vars} = Palette.tokens(%{"custom_palette_seed" => "#ff6b35"}, %{}, @group)

      assert vars["--theme-primary"] == "#ff6b35"
      assert vars["--theme-canvas"]
    end

    test "a seed stored alone derives in the group's seed_mode and follows the OS" do
      group = Map.put(@light_seed, :follow_os, true)
      seed_only = Palette.tokens(%{"custom_palette_seed" => "#ff6b35"}, %{}, group)

      assert seed_only ==
               Palette.tokens(
                 %{"color_scheme" => "default", "custom_palette_seed" => "#ff6b35"},
                 %{},
                 group
               )

      assert seed_only.dark_vars != %{}
    end

    test "emits nothing when neither a seed nor a scheme is stored" do
      assert Palette.tokens(%{}, %{}, @group) == %{vars: %{}, dark_vars: %{}}

      assert Palette.tokens(%{"custom_palette_seed" => ""}, %{}, @group) ==
               %{vars: %{}, dark_vars: %{}}
    end

    test "a dark scheme has no dark counterpart, even in a group that follows the OS" do
      assert %{vars: vars, dark_vars: dark_vars} =
               Palette.tokens(%{"color_scheme" => "purple"}, %{}, @follow_os)

      assert vars["--theme-canvas"] == "#1e1b4b"
      assert dark_vars == %{}
    end

    test "a seed derives a light palette where the group's seed_mode is :light" do
      settings = %{"color_scheme" => "default", "custom_palette_seed" => "#ff6b35"}

      %{vars: light, dark_vars: none} = Palette.tokens(settings, %{}, @light_seed)
      %{vars: dark} = Palette.tokens(settings, %{}, @group)

      assert light["--theme-primary"] == "#d83a00"
      assert Colour.relative_luminance(light["--theme-canvas"]) > 0.9
      assert Colour.relative_luminance(dark["--theme-canvas"]) < 0.05
      assert none == %{}
    end

    test "a light seed that follows the OS shows, in dark mode, what a dark theme derives from it" do
      settings = %{"color_scheme" => "default", "custom_palette_seed" => "#ff6b35"}

      %{dark_vars: dark_vars} =
        Palette.tokens(settings, %{}, Map.put(@light_seed, :follow_os, true))

      assert dark_vars != %{}
      assert dark_vars == Palette.tokens(settings, %{}, @group).vars
    end
  end

  describe "tokens/4" do
    test "merges the palette's variables over what the groups before it produced" do
      acc = %{
        vars: %{"--earlier" => "1", "--theme-primary" => "#000000"},
        dark_vars: %{"--earlier-dark" => "2"}
      }

      %{vars: vars, dark_vars: dark_vars} =
        Palette.tokens(%{"color_scheme" => "purple"}, %{}, acc, @group)

      assert vars["--earlier"] == "1"
      assert vars["--theme-primary"] == "#8b5cf6"
      assert vars["--theme-canvas"] == "#1e1b4b"
      assert dark_vars == %{"--earlier-dark" => "2"}
    end

    test "adds the dark set of a light scheme that follows the OS" do
      settings = %{"color_scheme" => "default", "custom_palette_seed" => "#123456"}
      group = Map.put(@light_seed, :follow_os, true)

      %{dark_vars: dark_vars} =
        Palette.tokens(settings, %{}, %{vars: %{}, dark_vars: %{}}, group)

      assert dark_vars != %{}
      assert dark_vars == Palette.tokens(settings, %{}, @group).vars
    end

    test "leaves what came before as it was when no palette resolves" do
      acc = %{vars: %{"--earlier" => "1"}, dark_vars: %{}}

      assert Palette.tokens(%{"color_scheme" => "nope"}, %{}, acc, @group) == acc
    end
  end

  describe "scheme_tokens/3" do
    test "a light scheme's own colours go into vars, and without follow_os nothing else" do
      %{vars: vars, dark_vars: dark_vars} = Palette.scheme_tokens(@light_scheme, %{}, @group)

      assert vars["--theme-canvas"] == "#faf7f2"
      assert vars["--theme-text"] == "#1f1b16"
      assert filled_pair_clears_aa?(vars)
      assert dark_vars == %{}
    end

    test "with follow_os its dark colours become a complete dark_vars set" do
      %{vars: vars, dark_vars: dark_vars} = Palette.scheme_tokens(@light_scheme, %{}, @follow_os)

      assert vars["--theme-canvas"] == "#faf7f2"
      assert dark_vars["--theme-canvas"] == "#1b1a24"
      assert dark_vars["--theme-primary"] == "#e0875c"
      assert Enum.sort(Map.keys(dark_vars)) == Enum.sort(Map.keys(vars))
      assert filled_pair_clears_aa?(dark_vars)
    end

    test "a primary-colour override applies to both sets, each with its own contrast pairs" do
      %{vars: vars, dark_vars: dark_vars} =
        Palette.scheme_tokens(@light_scheme, %{primary_color: "#e11d48"}, @follow_os)

      assert vars["--theme-primary"] == "#e11d48"
      assert dark_vars["--theme-primary"] == "#e11d48"
      assert filled_pair_clears_aa?(vars)
      assert filled_pair_clears_aa?(dark_vars)
    end
  end
end
