defmodule Tymeslot.Themes.CatalogTest do
  use Tymeslot.DataCase, async: true

  @moduletag :themes

  alias Config.Reader
  alias Tymeslot.Test.FixtureThemeSpec
  alias Tymeslot.Themes.Catalog

  test "exposes theme facts as the domain source of truth" do
    assert %{quill: %{key: :quill, id: "1"}, rhythm: %{key: :rhythm}} = Catalog.all()

    active = Catalog.active()
    assert [:quill, :rhythm] -- Map.keys(active) == []
    assert Enum.all?(active, fn {_key, theme} -> theme.status == :active end)

    assert %{key: :quill, id: "1", status: :active} = Catalog.default()
    assert Catalog.valid_id?(Catalog.default_id())
  end

  test "holds facts only, not display copy or flow shape" do
    for {_key, facts} <- Catalog.all() do
      refute Map.has_key?(facts, :description)
      refute Map.has_key?(facts, :flow_type)
      refute Map.has_key?(facts, :step_count)
    end

    assert map_size(Catalog.all()) > 0
  end

  test "gives every theme a heading style" do
    for {_key, facts} <- Catalog.all() do
      assert facts.heading_style in [:named, :generic]
    end

    assert Catalog.default().heading_style == :generic
  end

  test "names each theme's customisation spec" do
    assert Catalog.customization_spec("1") == {:ok, Tymeslot.ThemeCustomizations.QuillSpec}
    assert Catalog.customization_spec("2") == {:ok, Tymeslot.ThemeCustomizations.RhythmSpec}
    assert Catalog.customization_spec("9") == {:error, :theme_not_found}
  end

  describe "themes registered through :extra_themes" do
    test "join the catalogue in the test environment, hidden as beta" do
      assert {:ok, %{key: :fixture, status: :beta, customization_spec: spec} = facts} =
               Catalog.get_by_id("99")

      assert spec == FixtureThemeSpec
      refute Map.has_key?(facts, :module)
      refute Map.has_key?(Catalog.active(), :fixture)
    end

    test "are never registered outside the test environment" do
      for env <- [:dev, :prod] do
        config = Reader.read!("config/config.exs", env: env)
        assert config[:tymeslot][:extra_themes] in [nil, []], "#{env} registers extra themes"
      end

      refute File.read!("config/runtime.exs") =~ "extra_themes"
    end

    test "may not reuse a shipped theme's id or key" do
      shipped = %{quill: %{id: "1", key: :quill}}
      own = %{id: "7", key: :own, module: :own_module}

      assert %{quill: %{id: "1"}, own: %{id: "7"} = merged} =
               Catalog.merge_extra_themes!(shipped, [own])

      refute Map.has_key?(merged, :module)

      assert_raise ArgumentError, ~r/:own \(id "1"\) clashes with .*:quill \(id "1"\)/, fn ->
        Catalog.merge_extra_themes!(shipped, [%{own | id: "1"}])
      end

      assert_raise ArgumentError, ~r/:quill \(id "7"\) clashes with .*:quill/, fn ->
        Catalog.merge_extra_themes!(shipped, [%{own | key: :quill}])
      end
    end
  end
end
