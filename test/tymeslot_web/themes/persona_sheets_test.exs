defmodule TymeslotWeb.Themes.PersonaSheetsTest do
  @moduledoc """
  A booking theme starts from its persona sheet (`docs/themes/<key>.md`), and
  the theme guide's "Start from a story" chapter lists the seven axes a
  sheet takes its values from. Whoever designs the next theme reads both, so
  both must say what the code says: every shipped theme has a sheet whose
  story and axes are the ones its theme module declares (`story/0`,
  `axes/0`), the guide links that sheet, and the guide's axes table lists
  exactly the values `TymeslotWeb.Themes.Core.Axes.values/1` accepts.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :docs

  alias TymeslotWeb.Themes.Core.Axes
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.ThemeTestMatrix

  @guide "docs/THEME_DEVELOPMENT_GUIDE.md"
  @axes [:flow, :entry, :spatial, :time_view, :conversion, :voice, :surface]

  # The rows between the first `<!-- axes:start -->` and the next
  # `<!-- axes:end -->` in `path`, as `{axis, values}`: the backticked words
  # of each row, the first naming the axis. They stay strings, so a misspelt
  # value shows in the assertion's diff. The guide's sheet template repeats
  # the markers further down, inside a code block; only the first pair is
  # read.
  defp axes_table(path) do
    [_before, rest] = path |> File.read!() |> String.split("<!-- axes:start -->", parts: 2)
    [table, _after] = String.split(rest, "<!-- axes:end -->", parts: 2)

    for "| `" <> _cells = line <- String.split(table, "\n") do
      [axis | values] =
        ~r/`([a-z_]+)`/
        |> Regex.scan(line, capture: :all_but_first)
        |> List.flatten()

      {axis, values}
    end
  end

  defp sheet(slug), do: "docs/themes/#{slug}.md"

  defp story(id) do
    Gettext.with_locale(TymeslotWeb.Gettext, "en", fn ->
      ThemeInfo.get_theme_module(id).story()
    end)
  end

  test "the guide lists every axis once, in order, with exactly the values Axes accepts" do
    assert axes_table(@guide) ==
             for(
               axis <- @axes,
               do: {Atom.to_string(axis), Enum.map(Axes.values(axis), &Atom.to_string/1)}
             )
  end

  test "there are shipped themes to hold to their sheets" do
    assert ThemeTestMatrix.all() != []
  end

  for theme <- ThemeTestMatrix.all() do
    test "#{theme.name}: its persona sheet takes one value on each axis, its theme's" do
      table = axes_table(sheet(unquote(theme.slug)))
      module = ThemeInfo.get_theme_module(unquote(theme.id))

      assert Enum.map(table, &elem(&1, 0)) == Enum.map(@axes, &Atom.to_string/1)
      assert Enum.reject(table, &match?({_axis, [_value]}, &1)) == []

      assert Map.new(table, fn {axis, [value]} -> {axis, value} end) ==
               Map.new(module.axes(), fn {axis, value} ->
                 {Atom.to_string(axis), Atom.to_string(value)}
               end)
    end

    test "#{theme.name}: its persona sheet tells the story its theme declares, word for word" do
      assert File.read!(sheet(unquote(theme.slug))) =~ "\n> #{story(unquote(theme.id))}\n"
    end

    # The guide's link is documentation, so there is no Tymeslot function to call.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "#{theme.name}: the guide links its persona sheet" do
      assert File.read!(@guide) =~ "(themes/#{unquote(theme.slug)}.md)"
    end
  end
end
