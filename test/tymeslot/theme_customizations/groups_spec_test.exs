defmodule Tymeslot.Test.ThemeCustomizations.GroupsSpecTest do
  @moduledoc """
  The shared option groups, declared together on a test-only spec
  (`test/support/theme_customizations/groups_spec.ex`) and driven through
  `Specs` and the spec's generated callbacks, as a theme's spec would use
  them. None of the shared modules knows the spec exists.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.Test.ThemeCustomizations.GroupsSpec
  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Density
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias Tymeslot.ThemeCustomizations.Specs
  alias TymeslotWeb.Themes.Shared.ThemeStyle

  defp defaults, do: Map.new(GroupsSpec.defaults(), fn {k, v} -> {Atom.to_string(k), v} end)

  defp validate(attrs) do
    {%{}, Specs.setting_types(GroupsSpec)}
    |> Changeset.change()
    |> GroupsSpec.changeset(attrs)
  end

  defp in_mode(mode, overrides \\ %{}),
    do: GroupsSpec.tokens(Map.put(defaults(), "colour_mode", mode), overrides)

  describe "settings" do
    test "are every declared group's" do
      assert Specs.setting_types(GroupsSpec) ==
               Palette.types()
               |> Map.merge(ColourMode.types())
               |> Map.merge(Accent.types())
               |> Map.merge(Font.types())
               |> Map.merge(Radius.types())
               |> Map.merge(Density.types())
    end

    test "the defaults pass the generated changeset" do
      assert validate(defaults()).valid?
    end
  end

  describe "accent" do
    test "the generated changeset refuses an accent the group does not list" do
      changeset = validate(Map.put(defaults(), "accent", "chartreuse"))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :accent)
    end

    test "the stored accent is the page's primary, in both colour sets" do
      tokens = GroupsSpec.tokens(Map.put(defaults(), "accent", "cobalt"), %{})

      assert tokens.vars["--theme-primary"] == "#2563eb"
      assert tokens.dark_vars["--theme-primary"] == "#4a7eee"
    end

    test "the group's default applies when no accent is stored" do
      tokens = GroupsSpec.tokens(Map.delete(defaults(), "accent"), %{})

      assert tokens.vars["--theme-primary"] == "#07819e"
      assert tokens.dark_vars["--theme-primary"] == "#0891b2"
    end

    test "an embed's primary colour wins over the stored accent" do
      tokens =
        GroupsSpec.tokens(Map.put(defaults(), "accent", "cobalt"), %{primary_color: "#e11d48"})

      assert tokens.vars["--theme-primary"] == "#e11d48"
      assert tokens.dark_vars["--theme-primary"] == "#e8496c"
    end
  end

  describe "colour mode" do
    test "light shows the tone's light set, and writes no dark block" do
      tokens = in_mode("light")

      assert tokens.vars["--theme-canvas"] == "#f5f5f5"
      assert tokens.vars["--theme-color-scheme"] == "light"
      assert tokens.dark_vars == %{}
      refute ThemeStyle.css(tokens) =~ "prefers-color-scheme"
    end

    test "dark shows the tone's dark set on the page, and writes no dark block" do
      tokens = in_mode("dark")

      assert tokens.vars["--theme-canvas"] == "#0e0e10"
      assert tokens.vars["--theme-surface"] == "#18181b"
      assert tokens.vars["--theme-color-scheme"] == "dark"
      assert tokens.dark_vars == %{}
      refute ThemeStyle.css(tokens) =~ "prefers-color-scheme"
    end

    test "auto shows the light set, and the dark set inside the dark media query" do
      tokens = in_mode("auto")

      assert tokens.vars["--theme-canvas"] == "#f5f5f5"
      assert tokens.vars["--theme-color-scheme"] == "light dark"
      assert tokens.dark_vars["--theme-canvas"] == "#0e0e10"
      assert ThemeStyle.css(tokens) =~ "@media (prefers-color-scheme: dark)"
    end

    test "the accent follows the sets the mode chose" do
      assert in_mode("light").vars["--theme-primary"] == "#07819e"
      assert in_mode("dark").vars["--theme-primary"] == "#0891b2"
    end

    test "an embed's primary colour applies in every mode" do
      override = %{primary_color: "#e11d48"}

      assert in_mode("light", override).vars["--theme-primary"] == "#e11d48"
      assert in_mode("dark", override).vars["--theme-primary"] == "#e8496c"

      auto = in_mode("auto", override)
      assert auto.vars["--theme-primary"] == "#e11d48"
      assert auto.dark_vars["--theme-primary"] == "#e8496c"
    end

    test "the generated changeset refuses a mode the group does not have" do
      refute validate(Map.put(defaults(), "colour_mode", "sepia")).valid?
    end
  end

  describe "font" do
    test "the default font's stacks reach the page, in both modes alike" do
      tokens = GroupsSpec.tokens(defaults(), %{})

      assert tokens.vars["--theme-font-family"] == "var(--font-stack-system)"
      assert tokens.vars["--theme-font-heading"] == "var(--font-heading-system)"
      refute Map.has_key?(tokens.dark_vars, "--theme-font-family")
    end

    test "the generated changeset refuses a font the group does not offer" do
      refute validate(Map.put(defaults(), "font", "editorial")).valid?
    end
  end

  describe "radius and density" do
    test "their defaults reach the page" do
      %{vars: vars} = GroupsSpec.tokens(defaults(), %{})

      assert {vars["--radius-control"], vars["--radius-card"], vars["--density"]} ==
               {"8px", "12px", "1"}
    end

    test "a stored choice replaces the default" do
      settings = Map.merge(defaults(), %{"radius" => "sharp", "density" => "compact"})
      %{vars: vars} = GroupsSpec.tokens(settings, %{})

      assert {vars["--radius-control"], vars["--radius-card"], vars["--density"]} ==
               {"2px", "4px", "0.75"}
    end

    test "the generated changeset refuses a value either group does not have" do
      refute validate(Map.put(defaults(), "radius", "pill")).valid?
      refute validate(Map.put(defaults(), "density", "cosy")).valid?
    end
  end
end
