defmodule TymeslotWeb.Themes.Core.RegistryTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Core.Registry
  alias TymeslotWeb.Themes.Core.Registry.Definitions

  describe "default theme" do
    test "is the catalog's default, by id and by key" do
      assert Registry.default_theme_id() == Catalog.default_id()
      assert Registry.default_theme_key() == Catalog.default_key()
      assert {:ok, %{key: key}} = Registry.get_theme_by_id(Registry.default_theme_id())
      assert key == Catalog.default_key()
    end
  end

  describe "get_theme_by_slug/1" do
    test "finds every catalogue theme by its key as a string" do
      themes = Catalog.all()
      assert map_size(themes) > 0

      for {key, %{id: id}} <- themes do
        assert {:ok, %{id: ^id, key: ^key}} = Registry.get_theme_by_slug(Atom.to_string(key))
      end
    end

    test "does not find an unknown slug, and creates no atom for it" do
      slug = "no-such-theme-#{System.unique_integer([:positive])}"

      assert Registry.get_theme_by_slug(slug) == {:error, :theme_not_found}
      assert_raise ArgumentError, fn -> String.to_existing_atom(slug) end
    end
  end

  describe "themes registered through :extra_themes" do
    test "are bound to the module their entry names" do
      assert {:ok, %{key: :fixture, module: TymeslotWeb.Test.FixtureTheme.Theme}} =
               Registry.get_theme_by_id("99")

      assert {:ok, %{id: "99"}} = Registry.get_theme_by_slug("fixture")
    end
  end

  describe "Definitions.build!/2" do
    @facts %{
      alpha: %{id: "1", key: :alpha, name: "Alpha"},
      beta: %{id: "2", key: :beta, name: "Beta"}
    }

    test "gives each theme its conventional module, by key" do
      assert Definitions.build!(@facts, %{}) == %{
               alpha: %{
                 id: "1",
                 key: :alpha,
                 name: "Alpha",
                 module: TymeslotWeb.Themes.Alpha.Theme
               },
               beta: %{id: "2", key: :beta, name: "Beta", module: TymeslotWeb.Themes.Beta.Theme}
             }
    end

    test "camelizes keys with underscores" do
      assert Definitions.conventional_module(:soft_ink) == TymeslotWeb.Themes.SoftInk.Theme
    end

    test "an extra binding overrides the conventional module" do
      themes = Definitions.build!(@facts, %{"2" => BetaTheme})

      assert themes.alpha.module == TymeslotWeb.Themes.Alpha.Theme
      assert themes.beta.module == BetaTheme
    end

    test "refuses an extra binding with no Catalog theme, naming its id" do
      error =
        assert_raise ArgumentError, fn ->
          Definitions.build!(@facts, %{"2" => BetaTheme, "7" => GammaTheme})
        end

      assert error.message =~ ~s(:extra_themes entries with no Tymeslot.Themes.Catalog theme)
      assert error.message =~ ~s(["7"])
    end
  end

  describe "the shipped registry" do
    test "holds exactly the Catalog's themes" do
      assert Registry.all_themes() |> Map.keys() |> Enum.sort() ==
               Catalog.all() |> Map.keys() |> Enum.sort()
    end

    test "gives every shipped theme its conventional, loadable module" do
      extra_ids = :tymeslot |> Application.get_env(:extra_themes, []) |> Enum.map(& &1.id)

      for {key, theme} <- Registry.all_themes(), theme.id not in extra_ids do
        expected = Definitions.conventional_module(key)

        assert theme.module == expected
        # The module name must match the key, so a theme whose module does not
        # follow the convention fails here, naming its key.
        assert Code.ensure_loaded?(expected),
               "theme #{inspect(key)} must define #{inspect(expected)} " <>
                 "(lib/tymeslot_web/themes/#{key}/theme.ex)"
      end
    end
  end
end
