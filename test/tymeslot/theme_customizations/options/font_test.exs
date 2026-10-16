defmodule Tymeslot.ThemeCustomizations.Options.FontTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Shared.ThemeStyle

  @group %{key: :font, module: Font, presets: ~w(system inter plex), default: "system"}
  @acc %{vars: %{"--theme-primary" => "#0e7490"}, dark_vars: %{"--theme-canvas" => "#0e0e10"}}

  defp changeset(attrs),
    do: {%{}, Font.types()} |> Changeset.change() |> Font.changeset(attrs, @group)

  describe "changeset/3" do
    test "accepts a font the group lists" do
      assert changeset(%{"font" => "plex"}).valid?
    end

    test "refuses a font the group does not list, even one the catalogue has" do
      refute changeset(%{"font" => "classic"}).valid?
      refute changeset(%{"font" => "comic-sans"}).valid?
    end
  end

  describe "changes/3" do
    test "a font choice writes the setting" do
      assert Font.changes("font", "inter", @group) == {:ok, %{"font" => "inter"}}
      assert Font.changes("size", "large", @group) == :error
    end
  end

  describe "tokens/4" do
    test "points the body and heading fonts at the stored font's stacks" do
      %{vars: vars} = Font.tokens(%{"font" => "plex"}, %{}, @acc, @group)

      assert vars["--theme-font-family"] == "var(--font-stack-plex)"
      assert vars["--theme-font-heading"] == "var(--font-heading-plex)"
      assert vars["--theme-primary"] == "#0e7490"
    end

    test "uses the group's default when nothing is stored" do
      assert Font.tokens(%{}, %{}, @acc, @group).vars["--theme-font-family"] ==
               "var(--font-stack-system)"
    end

    test "leaves the dark set alone: fonts do not change with the colour mode" do
      assert Font.tokens(%{"font" => "plex"}, %{}, @acc, @group).dark_vars == @acc.dark_vars
    end

    test "an id the catalogue does not hold gives the default's stacks" do
      assert Font.tokens(%{"font" => "evil) ; x"}, %{}, @acc, @group) ==
               Font.tokens(%{}, %{}, @acc, @group)
    end

    test "an id in the catalogue but not in the group's presets gives the default's stacks" do
      assert Font.tokens(%{"font" => "classic"}, %{}, @acc, @group) ==
               Font.tokens(%{}, %{}, @acc, @group)

      assert Font.tokens(%{"font" => "classic"}, %{}, @acc, @group).vars["--theme-font-family"] ==
               "var(--font-stack-system)"
    end

    test "writes only what ThemeStyle lets through, never a family name" do
      %{vars: vars} = Font.tokens(%{"font" => "inter"}, %{}, %{vars: %{}, dark_vars: %{}}, @group)
      css = ThemeStyle.css(%Tokens{vars: vars})

      assert css =~ "--theme-font-family: var(--font-stack-inter);"
      assert css =~ "--theme-font-heading: var(--font-heading-inter);"
      refute css =~ "'"
    end
  end

  describe "choice/2" do
    test "is the stored id when the group lists it, else the default" do
      assert Font.choice(%{"font" => "plex"}, @group) == "plex"
      assert Font.choice(%{}, @group) == "system"
      assert Font.choice(%{"font" => "nope"}, @group) == "system"
      assert Font.choice(%{"font" => "classic"}, @group) == "system"
    end
  end

  describe "presets/1" do
    test "are the group's fonts, in the group's order" do
      assert [{"system", %{name: "System"}}, {"inter", %{name: "Inter"}}, {"plex", _plex}] =
               Font.presets(@group)
    end
  end
end
