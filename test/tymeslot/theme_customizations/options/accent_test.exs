defmodule Tymeslot.ThemeCustomizations.Options.AccentTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Accent

  @group %{
    key: :accent,
    module: Accent,
    presets: ~w(tymeslot cobalt graphite),
    default: "tymeslot"
  }

  # The variables a `?primary-color=` override replaces on a palette alone.
  @family ~w(--theme-primary --theme-primary-hover --theme-on-primary --theme-primary-solid --theme-primary-solid-hover)

  # What a light tone's palette produces before the accent, and its dark set.
  @light %{
    "--theme-canvas" => "#f5f5f5",
    "--theme-surface" => "#ffffff",
    "--theme-text" => "#111111",
    "--theme-text-secondary" => "#5f6368",
    "--theme-accent" => "#0d9488",
    "--theme-primary" => "#0e7490",
    "--theme-primary-hover" => "#155e75",
    "--theme-on-primary" => "#ffffff",
    "--theme-primary-solid" => "#0e7490",
    "--theme-primary-solid-hover" => "#155e75"
  }

  @dark %{
    "--theme-canvas" => "#0e0e10",
    "--theme-surface" => "#18181b",
    "--theme-text" => "#f4f4f5",
    "--theme-text-secondary" => "#a1a1aa",
    "--theme-accent" => "#2dd4bf",
    "--theme-primary" => "#22d3ee",
    "--theme-primary-hover" => "#06b6d4",
    "--theme-on-primary" => "#0e0e10",
    "--theme-primary-solid" => "#22d3ee",
    "--theme-primary-solid-hover" => "#06b6d4"
  }

  @both %{vars: @light, dark_vars: @dark}

  defp changeset(attrs),
    do: {%{}, Accent.types()} |> Changeset.change() |> Accent.changeset(attrs, @group)

  describe "changeset/3" do
    test "accepts a preset the group lists" do
      assert changeset(%{"accent" => "cobalt"}).valid?
    end

    test "refuses a preset the group does not list, even one the catalogue has" do
      changeset = changeset(%{"accent" => "rose"})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :accent)
    end

    test "stores a custom colour as lower-case #rrggbb" do
      assert Changeset.get_change(changeset(%{"accent" => "#2563EB"}), :accent) == "#2563eb"
      assert Changeset.get_change(changeset(%{"accent" => "#abc"}), :accent) == "#aabbcc"
    end

    test "refuses a malformed custom colour" do
      refute changeset(%{"accent" => "#12"}).valid?
      refute changeset(%{"accent" => "#gggggg"}).valid?
    end

    test "leaves the setting alone when it is not given" do
      assert changeset(%{}).valid?
    end
  end

  describe "changes/3" do
    test "a preset and a custom colour both write the accent" do
      assert Accent.changes("preset", "cobalt", @group) == {:ok, %{"accent" => "cobalt"}}
      assert Accent.changes("custom", "#123456", @group) == {:ok, %{"accent" => "#123456"}}
    end

    test "refuses a field the group does not have" do
      assert Accent.changes("scheme", "cobalt", @group) == :error
    end
  end

  describe "choice/2 and colour/2" do
    test "a stored preset is its catalogue colour" do
      assert Accent.choice(%{"accent" => "cobalt"}, @group) == "cobalt"
      assert Accent.colour(%{"accent" => "cobalt"}, @group) == "#2563eb"
    end

    test "a stored custom colour is itself" do
      assert Accent.colour(%{"accent" => "#123456"}, @group) == "#123456"
    end

    test "nothing stored is the group's default" do
      assert Accent.choice(%{}, @group) == "tymeslot"
      assert Accent.colour(%{}, @group) == "#0891b2"
    end

    test "an id the catalogue does not hold is the default" do
      assert Accent.choice(%{"accent" => "nope"}, @group) == "tymeslot"
      assert Accent.colour(%{"accent" => "nope"}, @group) == "#0891b2"
    end

    test "an id in the catalogue but not in the group's presets is the default" do
      assert Accent.choice(%{"accent" => "indigo"}, @group) == "tymeslot"
      assert Accent.colour(%{"accent" => "indigo"}, @group) == "#0891b2"
    end

    test "a malformed custom colour is the default" do
      assert Accent.choice(%{"accent" => "#12"}, @group) == "tymeslot"
    end
  end

  describe "presets/1" do
    test "are the group's presets, in the group's order" do
      assert [
               {"tymeslot", %{color: "#0891b2"}},
               {"cobalt", _cobalt},
               {"graphite", %{color: "#374151"}}
             ] =
               Accent.presets(@group)
    end
  end

  describe "tokens/4" do
    test "replaces the primary family, and nothing else, in each colour set" do
      %{vars: vars, dark_vars: dark_vars} =
        Accent.tokens(%{"accent" => "cobalt"}, %{}, @both, @group)

      assert Map.drop(vars, @family) == Map.drop(@light, @family)
      assert Map.drop(dark_vars, @family) == Map.drop(@dark, @family)
      assert vars["--theme-primary"] == "#2563eb"
      assert dark_vars["--theme-primary"] == "#4a7eee"
    end

    test "an unknown or unlisted id gives the default accent's tokens, not the tone's primary" do
      expected = Accent.tokens(%{}, %{}, @both, @group)

      for stored <- ["nope", "indigo"] do
        assert Accent.tokens(%{"accent" => stored}, %{}, @both, @group) == expected,
               "for #{stored}"
      end

      assert expected.vars["--theme-primary"] != @light["--theme-primary"]
    end

    test "fits the accent as text on each set's card" do
      %{vars: vars, dark_vars: dark_vars} = Accent.tokens(%{}, %{}, @both, @group)

      # #0891b2 is 3.68:1 on white, so it darkens; on the dark card it reads.
      assert vars["--theme-primary"] == "#07819e"
      assert dark_vars["--theme-primary"] == "#0891b2"
    end

    test "derives the hover shade and the filled-control pair from the fitted accent" do
      %{vars: vars} =
        Accent.tokens(%{"accent" => "graphite"}, %{}, %{vars: @light, dark_vars: %{}}, @group)

      assert Map.take(vars, @family) == %{
               "--theme-primary" => "#374151",
               "--theme-primary-hover" => "#272d39",
               "--theme-on-primary" => "#ffffff",
               "--theme-primary-solid" => "#374151",
               "--theme-primary-solid-hover" => "#272d39"
             }
    end

    test "leaves an empty dark set empty" do
      assert %{dark_vars: %{}} =
               Accent.tokens(
                 %{"accent" => "cobalt"},
                 %{},
                 %{vars: @light, dark_vars: %{}},
                 @group
               )
    end

    test "a page-view primary colour wins over the stored accent, fitted the same way" do
      %{vars: vars, dark_vars: dark_vars} =
        Accent.tokens(%{"accent" => "cobalt"}, %{primary_color: "#e11d48"}, @both, @group)

      assert vars["--theme-primary"] == "#e11d48"
      assert dark_vars["--theme-primary"] == "#e8496c"
    end

    test "reads the canvas as the card where the surface is translucent" do
      dark = %{"--theme-canvas" => "#1d110c", "--theme-surface" => "rgba(60, 40, 32, 0.5)"}

      %{dark_vars: dark_vars} =
        Accent.tokens(%{"accent" => "cobalt"}, %{}, %{vars: @light, dark_vars: dark}, @group)

      assert dark_vars["--theme-primary"] == "#4a7eee"
    end

    test "with no palette before it, puts the accent in as it is" do
      %{vars: vars} =
        Accent.tokens(%{"accent" => "cobalt"}, %{}, %{vars: %{}, dark_vars: %{}}, @group)

      assert vars["--theme-primary"] == "#2563eb"
      assert vars["--theme-on-primary"] == "#ffffff"
    end

    test "with nothing to resolve, changes nothing" do
      group = %{@group | presets: ["nope"], default: "nope"}

      assert Accent.tokens(%{"accent" => "nope"}, %{}, @both, group) == @both
    end
  end
end
