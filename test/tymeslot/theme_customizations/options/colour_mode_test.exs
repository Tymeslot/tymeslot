defmodule Tymeslot.ThemeCustomizations.Options.ColourModeTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.ColourMode

  @group %{key: :colour_mode, module: ColourMode, default: "auto"}

  # What a palette with follow_os: true produces for a light tone.
  @light %{"--theme-canvas" => "#f5f5f5", "--theme-text" => "#111111"}
  @dark %{"--theme-canvas" => "#0e0e10", "--theme-text" => "#f4f4f5"}
  @both %{vars: @light, dark_vars: @dark}

  defp changeset(attrs),
    do: {%{}, ColourMode.types()} |> Changeset.change() |> ColourMode.changeset(attrs, @group)

  describe "changeset/3" do
    test "accepts light, dark and auto" do
      for mode <- ~w(light dark auto), do: assert(changeset(%{"colour_mode" => mode}).valid?)
    end

    test "refuses any other mode" do
      changeset = changeset(%{"colour_mode" => "sepia"})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :colour_mode)
    end
  end

  describe "changes/3" do
    test "a mode choice writes the setting" do
      assert ColourMode.changes("mode", "dark", @group) == {:ok, %{"colour_mode" => "dark"}}
    end

    test "refuses a field the group does not have" do
      assert ColourMode.changes("scheme", "dark", @group) == :error
    end
  end

  describe "mode/2" do
    test "is the stored mode, else the group's default" do
      assert ColourMode.mode(%{"colour_mode" => "light"}, @group) == "light"
      assert ColourMode.mode(%{}, @group) == "auto"
      assert ColourMode.mode(%{"colour_mode" => "sepia"}, @group) == "auto"
    end
  end

  describe "tokens/4" do
    test "light keeps the page's set and drops the dark one" do
      assert ColourMode.tokens(%{"colour_mode" => "light"}, %{}, @both, @group) == %{
               vars: Map.put(@light, "--theme-color-scheme", "light"),
               dark_vars: %{}
             }
    end

    test "dark shows the dark set on the page, whatever the OS" do
      assert ColourMode.tokens(%{"colour_mode" => "dark"}, %{}, @both, @group) == %{
               vars: Map.put(@dark, "--theme-color-scheme", "dark"),
               dark_vars: %{}
             }
    end

    test "auto keeps both sets, the dark one for a dark OS" do
      assert ColourMode.tokens(%{"colour_mode" => "auto"}, %{}, @both, @group) == %{
               vars: Map.put(@light, "--theme-color-scheme", "light dark"),
               dark_vars: @dark
             }
    end

    test "nothing stored is the group's default" do
      assert ColourMode.tokens(%{}, %{}, @both, @group).dark_vars == @dark
    end

    test "dark with no dark set to choose keeps the page's colours" do
      assert ColourMode.tokens(
               %{"colour_mode" => "dark"},
               %{},
               %{vars: @light, dark_vars: %{}},
               @group
             ) ==
               %{vars: Map.put(@light, "--theme-color-scheme", "dark"), dark_vars: %{}}
    end
  end
end
