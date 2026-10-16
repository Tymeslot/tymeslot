defmodule Tymeslot.ThemeCustomizations.ShippedSchemeTokensTest do
  @moduledoc """
  Pins, value for value, the custom properties Quill's and Rhythm's
  `tokens/2` emit for every shipped colour scheme, for a few custom seeds and
  for a primary-colour override.

  Written before colour schemes learnt about light mode, so any change to the
  dark output shows up here first. Change a value only for an intended visual
  change, never to make a refactor pass.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.ThemeCustomizations.RhythmSpec
  alias Tymeslot.ThemeCustomizations.Specs

  # Palette vars per shipped scheme, without `--theme-background` (which the
  # background option adds, see @backgrounds).
  @schemes %{
    "default" => %{
      "--theme-accent" => "#10b981",
      "--theme-accent-solid" => "#10b981",
      "--theme-canvas" => "#0f172a",
      "--theme-on-accent" => "#0f172a",
      "--theme-on-primary" => "#0f172a",
      "--theme-primary" => "#06b6d4",
      "--theme-primary-hover" => "#0891b2",
      "--theme-primary-solid" => "#06b6d4",
      "--theme-primary-solid-hover" => "#0891b2",
      "--theme-secondary" => "#14b8a6",
      "--theme-surface" => "rgba(30, 41, 59, 0.5)",
      "--theme-text" => "#e2e8f0",
      "--theme-text-secondary" => "#94a3b8"
    },
    "forest" => %{
      "--theme-accent" => "#6ee7b7",
      "--theme-accent-solid" => "#6ee7b7",
      "--theme-canvas" => "#052e16",
      "--theme-on-accent" => "#052e16",
      "--theme-on-primary" => "#052e16",
      "--theme-primary" => "#10b981",
      "--theme-primary-hover" => "#059669",
      "--theme-primary-solid" => "#10b981",
      "--theme-primary-solid-hover" => "#06aa77",
      "--theme-secondary" => "#34d399",
      "--theme-surface" => "rgba(20, 83, 45, 0.5)",
      "--theme-text" => "#d1fae5",
      "--theme-text-secondary" => "#a7f3d0"
    },
    "monochrome" => %{
      "--theme-accent" => "#d1d5db",
      "--theme-accent-solid" => "#d1d5db",
      "--theme-canvas" => "#111827",
      "--theme-on-accent" => "#111827",
      "--theme-on-primary" => "#ffffff",
      "--theme-primary" => "#6b7280",
      "--theme-primary-hover" => "#4b5563",
      "--theme-primary-solid" => "#6b7280",
      "--theme-primary-solid-hover" => "#4b5563",
      "--theme-secondary" => "#9ca3af",
      "--theme-surface" => "rgba(31, 41, 55, 0.5)",
      "--theme-text" => "#f3f4f6",
      "--theme-text-secondary" => "#d1d5db"
    },
    "ocean" => %{
      "--theme-accent" => "#7dd3fc",
      "--theme-accent-solid" => "#7dd3fc",
      "--theme-canvas" => "#082f49",
      "--theme-on-accent" => "#082f49",
      "--theme-on-primary" => "#082f49",
      "--theme-primary" => "#0ea5e9",
      "--theme-primary-hover" => "#0284c7",
      "--theme-primary-solid" => "#0ea5e9",
      "--theme-primary-solid-hover" => "#029fef",
      "--theme-secondary" => "#38bdf8",
      "--theme-surface" => "rgba(12, 74, 110, 0.5)",
      "--theme-text" => "#e0f2fe",
      "--theme-text-secondary" => "#bae6fd"
    },
    "purple" => %{
      "--theme-accent" => "#c084fc",
      "--theme-accent-solid" => "#c084fc",
      "--theme-canvas" => "#1e1b4b",
      "--theme-on-accent" => "#1e1b4b",
      "--theme-on-primary" => "#ffffff",
      "--theme-primary" => "#8b5cf6",
      "--theme-primary-hover" => "#7c3aed",
      "--theme-primary-solid" => "#8452f5",
      "--theme-primary-solid-hover" => "#7c3aed",
      "--theme-secondary" => "#a78bfa",
      "--theme-surface" => "rgba(46, 38, 84, 0.5)",
      "--theme-text" => "#ede9fe",
      "--theme-text-secondary" => "#c4b5fd"
    },
    "rose" => %{
      "--theme-accent" => "#fda4af",
      "--theme-accent-solid" => "#fda4af",
      "--theme-canvas" => "#4c0519",
      "--theme-on-accent" => "#4c0519",
      "--theme-on-primary" => "#ffffff",
      "--theme-primary" => "#f43f5e",
      "--theme-primary-hover" => "#e11d48",
      "--theme-primary-solid" => "#e80d33",
      "--theme-primary-solid-hover" => "#e11d48",
      "--theme-secondary" => "#fb7185",
      "--theme-surface" => "rgba(136, 19, 55, 0.5)",
      "--theme-text" => "#ffe4e6",
      "--theme-text-secondary" => "#fecdd3"
    },
    "sunset" => %{
      "--theme-accent" => "#fbbf24",
      "--theme-accent-solid" => "#fbbf24",
      "--theme-canvas" => "#431407",
      "--theme-on-accent" => "#431407",
      "--theme-on-primary" => "#431407",
      "--theme-primary" => "#f97316",
      "--theme-primary-hover" => "#ea580c",
      "--theme-primary-solid" => "#f97316",
      "--theme-primary-solid-hover" => "#f35c0e",
      "--theme-secondary" => "#fb923c",
      "--theme-surface" => "rgba(92, 45, 10, 0.5)",
      "--theme-text" => "#fef3c7",
      "--theme-text-secondary" => "#fed7aa"
    },
    "turquoise" => %{
      "--theme-accent" => "#38bdf8",
      "--theme-accent-solid" => "#38bdf8",
      "--theme-canvas" => "#0c1426",
      "--theme-on-accent" => "#0c1426",
      "--theme-on-primary" => "#ffffff",
      "--theme-primary" => "#0284c7",
      "--theme-primary-hover" => "#0369a1",
      "--theme-primary-solid" => "#0277b3",
      "--theme-primary-solid-hover" => "#0369a1",
      "--theme-secondary" => "#0ea5e9",
      "--theme-surface" => "rgba(15, 23, 42, 0.6)",
      "--theme-text" => "#e0f2fe",
      "--theme-text-secondary" => "#7dd3fc"
    }
  }

  # A warm, a dark and a very bright seed: between them they take both inks
  # and both contrast-fitting directions.
  @seeds %{
    "#ff6b35" => %{
      "--theme-accent" => "#ffe282",
      "--theme-accent-solid" => "#ffe282",
      "--theme-canvas" => "#1d110c",
      "--theme-on-accent" => "#1d110c",
      "--theme-on-primary" => "#1d110c",
      "--theme-primary" => "#ff6b35",
      "--theme-primary-hover" => "#ff4d0c",
      "--theme-primary-solid" => "#ff6b35",
      "--theme-primary-solid-hover" => "#ff4d0c",
      "--theme-secondary" => "#f36c6a",
      "--theme-surface" => "rgba(60, 39, 32, 0.5)",
      "--theme-text" => "#eee9e8",
      "--theme-text-secondary" => "#c2b3ad"
    },
    "#123456" => %{
      "--theme-accent" => "#1f1f95",
      "--theme-accent-solid" => "#1f1f95",
      "--theme-canvas" => "#0c141d",
      "--theme-on-accent" => "#ffffff",
      "--theme-on-primary" => "#ffffff",
      "--theme-primary" => "#123456",
      "--theme-primary-hover" => "#0b2034",
      "--theme-primary-solid" => "#123456",
      "--theme-primary-solid-hover" => "#0b2034",
      "--theme-secondary" => "#205d71",
      "--theme-surface" => "rgba(32, 46, 60, 0.5)",
      "--theme-text" => "#e8ebee",
      "--theme-text-secondary" => "#adb8c2"
    },
    "#ffff00" => %{
      "--theme-accent" => "#a6ff4d",
      "--theme-accent-solid" => "#a6ff4d",
      "--theme-canvas" => "#1d1d0c",
      "--theme-on-accent" => "#1d1d0c",
      "--theme-on-primary" => "#1d1d0c",
      "--theme-primary" => "#ffff00",
      "--theme-primary-hover" => "#d6d600",
      "--theme-primary-solid" => "#ffff00",
      "--theme-primary-solid-hover" => "#d6d600",
      "--theme-secondary" => "#efc139",
      "--theme-surface" => "rgba(60, 60, 32, 0.5)",
      "--theme-text" => "#eeeee8",
      "--theme-text-secondary" => "#c2c2ad"
    }
  }

  # The default scheme with `?primary-color=#e11d48`.
  @override %{
    "--theme-accent" => "#10b981",
    "--theme-accent-solid" => "#10b981",
    "--theme-canvas" => "#0f172a",
    "--theme-on-accent" => "#0f172a",
    "--theme-on-primary" => "#ffffff",
    "--theme-primary" => "#e11d48",
    "--theme-primary-hover" => "#bd183c",
    "--theme-primary-solid" => "#e11d48",
    "--theme-primary-solid-hover" => "#bd183c",
    "--theme-secondary" => "#14b8a6",
    "--theme-surface" => "rgba(30, 41, 59, 0.5)",
    "--theme-text" => "#e2e8f0",
    "--theme-text-secondary" => "#94a3b8"
  }

  # What each spec's default background adds: Quill's Aurora gradient, and
  # the canvas behind Rhythm's video.
  @backgrounds %{
    QuillSpec => "linear-gradient(135deg, #667eea 0%, #764ba2 100%)",
    RhythmSpec => "var(--theme-canvas)"
  }

  defp settings(spec, extra) do
    spec.defaults()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(extra)
  end

  # The pins cover what Quill and Rhythm can show; a light tone in the
  # catalogue is not theirs.
  test "every scheme Quill and Rhythm offer is pinned" do
    for spec <- Map.keys(@backgrounds) do
      assert Enum.sort(Specs.group(spec, Palette).schemes) == Enum.sort(Map.keys(@schemes))
    end
  end

  for {spec_mod, background} <- @backgrounds do
    @spec_mod spec_mod
    @background background

    describe "#{inspect(spec_mod)}.tokens/2" do
      for {scheme, vars} <- @schemes do
        @scheme scheme
        @vars vars

        test "scheme #{scheme}" do
          tokens = @spec_mod.tokens(settings(@spec_mod, %{"color_scheme" => @scheme}), %{})

          assert tokens.vars == Map.put(@vars, "--theme-background", @background)
          assert tokens.dark_vars == %{}
        end
      end

      for {seed, vars} <- @seeds do
        @seed seed
        @vars vars

        test "custom seed #{seed}" do
          tokens = @spec_mod.tokens(settings(@spec_mod, %{"custom_palette_seed" => @seed}), %{})

          assert tokens.vars == Map.put(@vars, "--theme-background", @background)
          assert tokens.dark_vars == %{}
        end
      end

      test "primary-colour override on the default scheme" do
        tokens = @spec_mod.tokens(settings(@spec_mod, %{}), %{primary_color: "#e11d48"})

        assert tokens.vars == Map.put(@override, "--theme-background", @background)
        assert tokens.dark_vars == %{}
      end
    end
  end
end
