defmodule Tymeslot.ThemeCustomizations.Options.DensityTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Density

  @group %{key: :density, module: Density, default: "comfortable"}
  @acc %{vars: %{}, dark_vars: %{"--theme-canvas" => "#0e0e10"}}

  defp changeset(attrs),
    do: {%{}, Density.types()} |> Changeset.change() |> Density.changeset(attrs, @group)

  test "the changeset accepts comfortable and compact, and nothing else" do
    assert changeset(%{"density" => "comfortable"}).valid?
    assert changeset(%{"density" => "compact"}).valid?
    refute changeset(%{"density" => "cosy"}).valid?
  end

  test "a choice writes the setting" do
    assert Density.changes("density", "compact", @group) == {:ok, %{"density" => "compact"}}
    assert Density.changes("spacing", "compact", @group) == :error
  end

  test "each choice sets the density factor" do
    assert Density.tokens(%{"density" => "comfortable"}, %{}, @acc, @group).vars == %{
             "--density" => "1"
           }

    assert Density.tokens(%{"density" => "compact"}, %{}, @acc, @group).vars == %{
             "--density" => "0.75"
           }
  end

  test "nothing stored is the group's default, and the dark set is left alone" do
    tokens = Density.tokens(%{}, %{}, @acc, %{@group | default: "compact"})

    assert tokens.vars == %{"--density" => "0.75"}
    assert tokens.dark_vars == @acc.dark_vars
  end
end
