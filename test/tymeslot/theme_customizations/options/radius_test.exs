defmodule Tymeslot.ThemeCustomizations.Options.RadiusTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Radius

  @group %{key: :radius, module: Radius, default: "soft"}
  @acc %{vars: %{"--theme-primary" => "#0e7490"}, dark_vars: %{"--theme-canvas" => "#0e0e10"}}

  defp changeset(attrs),
    do: {%{}, Radius.types()} |> Changeset.change() |> Radius.changeset(attrs, @group)

  test "the changeset accepts sharp, soft and round, and nothing else" do
    for radius <- ~w(sharp soft round), do: assert(changeset(%{"radius" => radius}).valid?)

    changeset = changeset(%{"radius" => "pill"})
    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :radius)
  end

  test "a choice writes the setting" do
    assert Radius.changes("radius", "round", @group) == {:ok, %{"radius" => "round"}}
    assert Radius.changes("corners", "round", @group) == :error
  end

  test "each choice sets both radius roles" do
    lengths =
      for radius <- Radius.choices() do
        %{vars: vars} = Radius.tokens(%{"radius" => radius}, %{}, @acc, @group)
        {radius, vars["--radius-control"], vars["--radius-card"]}
      end

    assert lengths == [
             {"sharp", "2px", "4px"},
             {"soft", "8px", "12px"},
             {"round", "999px", "20px"}
           ]
  end

  test "nothing stored, or a value it does not know, is the group's default" do
    assert Radius.tokens(%{}, %{}, @acc, @group).vars["--radius-card"] == "12px"
    assert Radius.tokens(%{"radius" => "pill"}, %{}, @acc, @group).vars["--radius-card"] == "12px"
  end

  test "keeps what came before, and leaves the dark set alone" do
    tokens = Radius.tokens(%{"radius" => "round"}, %{}, @acc, @group)

    assert tokens.vars["--theme-primary"] == "#0e7490"
    assert tokens.dark_vars == @acc.dark_vars
  end
end
