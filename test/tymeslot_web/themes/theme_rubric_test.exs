defmodule TymeslotWeb.Themes.ThemeRubricTest do
  @moduledoc """
  Two shipped themes must tell different stories, whatever their colours:
  every pair differs on at least three of the seven design axes
  (`TymeslotWeb.Themes.Core.Axes`), as each theme declares them with
  `use TymeslotWeb.Themes.Core.Theme, axes: [...]`. A new theme starts from a
  persona whose axes pass this test, before any code is written.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Core.Axes
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.ThemeTestMatrix

  @minimum_differences 3

  # Pairs allowed below the minimum, by theme id, each with its reason.
  @exemptions %{
    {"1", "2"} =>
      "Quill and Rhythm differ on the spatial model and the time view only. They stay " <>
        "two themes; Rhythm's own (evocative) voice gives the pair its third difference, " <>
        "and the commit that lands it removes this exemption."
  }

  defp axes(id), do: ThemeInfo.get_theme_module(id).axes()

  defp pairs do
    ids = ThemeTestMatrix.ids()
    for a <- ids, b <- ids, String.to_integer(a) < String.to_integer(b), do: {a, b}
  end

  test "every pair of shipped themes differs on at least three axes" do
    assert pairs() != []

    too_close =
      pairs()
      |> Enum.reject(&Map.has_key?(@exemptions, &1))
      |> Enum.map(fn {a, b} = pair -> {pair, Axes.differences(axes(a), axes(b))} end)
      |> Enum.filter(fn {_pair, differences} -> length(differences) < @minimum_differences end)

    assert too_close == [],
           "These shipped themes tell too similar a story (each pair with the axes it " <>
             "differs on, fewer than #{@minimum_differences}): #{inspect(too_close)}. " <>
             "Change the newer theme's persona, not the rubric."
  end

  test "every exemption names a pair of shipped themes that still needs it" do
    shipped = MapSet.new(pairs())

    stale =
      Enum.reject(@exemptions, fn {{a, b} = pair, _reason} ->
        MapSet.member?(shipped, pair) and
          length(Axes.differences(axes(a), axes(b))) < @minimum_differences
      end)

    assert stale == [],
           "Remove these exemptions; the pair is no longer shipped or now passes the " <>
             "rubric on its own: #{inspect(stale)}"
  end
end
