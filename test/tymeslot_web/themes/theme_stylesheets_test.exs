defmodule TymeslotWeb.Themes.ThemeStylesheetsTest do
  @moduledoc """
  Pins the booking-page theme build list: one stylesheet per directory under
  `assets/css/scheduling/themes/`, which `config/theme_stylesheets.exs` lists
  for the Tailwind profiles, the dev watchers and the assets aliases.
  """

  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Config.Reader
  alias Mix.Project
  alias TymeslotWeb.ThemeTestMatrix

  @config_dir Path.expand("../../../config", __DIR__)

  defp stylesheets do
    {keys, _binding} = Code.eval_file("theme_stylesheets.exs", @config_dir)
    keys
  end

  # The shipped themes: a test-only fixture theme has no stylesheet, so no
  # directory. `ThemeTestMatrixTest` keeps `all/0` equal to the catalogue
  # minus the fixtures, so a catalogued theme without a directory still fails.
  test "every shipped theme has a stylesheet directory, and every directory a shipped theme" do
    assert stylesheets() ==
             ThemeTestMatrix.all() |> Enum.map(&Atom.to_string(&1.key)) |> Enum.sort()
  end

  # config/dev.exs derives `tailwind_<key>` watchers and config.exs a `:<key>`
  # Tailwind profile per theme, so these keys would overwrite Core's own
  # `:tymeslot` profile or the SaaS profiles and watchers.
  test "no theme directory takes a reserved stylesheet key" do
    assert Enum.filter(stylesheets(), &(&1 in ~w(tymeslot saas marketing))) == []
  end

  test "each theme's Tailwind profile builds the stylesheet the layout loads" do
    keys = stylesheets()
    assert keys != []

    wrong =
      Enum.reject(keys, fn key ->
        Application.get_env(:tailwind, String.to_existing_atom(key)) == [
          args: [
            "--input=css/scheduling/themes/#{key}/theme.css",
            "--output=../priv/static/assets/scheduling-theme-#{key}.css"
          ],
          cd: Path.expand("../assets", @config_dir)
        ]
      end)

    assert wrong == [], "themes without the expected Tailwind profile: #{inspect(wrong)}"
  end

  test "the dev server watches every theme stylesheet" do
    keys = stylesheets()
    assert keys != []

    watchers =
      Reader.read!(Path.join(@config_dir, "config.exs"), env: :dev)[:tymeslot][
        TymeslotWeb.Endpoint
      ][:watchers]

    unwatched =
      Enum.reject(keys, fn key ->
        watchers[String.to_existing_atom("tailwind_#{key}")] ==
          {Tailwind, :install_and_run, [String.to_existing_atom(key), ["--watch"]]}
      end)

    assert unwatched == [], "theme stylesheets with no dev watcher: #{inspect(unwatched)}"
  end

  test "assets.build and assets.minify build every theme stylesheet" do
    keys = stylesheets()
    assert keys != []
    aliases = Project.config()[:aliases]

    assert Enum.reject(keys, &("tailwind #{&1}" in aliases[:"assets.build"])) == []
    assert Enum.reject(keys, &("tailwind #{&1} --minify" in aliases[:"assets.minify"])) == []
  end
end
