defmodule Tymeslot.ThemeCustomizations.PresetsKindsTest do
  @moduledoc """
  Each kind of preset lives in a module of its own under `presets/`, and the
  `Presets` facade answers from them: the per-kind getters return each
  module's `all/0`, and `find_preset_by_id/2` and `take/2` reach every preset
  of every kind.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Presets.Accents
  alias Tymeslot.ThemeCustomizations.Presets.ColourSchemes
  alias Tymeslot.ThemeCustomizations.Presets.Fonts
  alias Tymeslot.ThemeCustomizations.Presets.Gradients
  alias Tymeslot.ThemeCustomizations.Presets.Images
  alias Tymeslot.ThemeCustomizations.Presets.Videos
  alias Tymeslot.Utils.Colour

  @kinds [
    {:color_scheme, ColourSchemes, &Presets.get_color_schemes/0},
    {:gradient, Gradients, &Presets.get_gradient_presets/0},
    {:image, Images, &Presets.get_image_presets/0},
    {:video, Videos, &Presets.get_video_presets/0}
  ]

  for {kind, module, _getter} <- @kinds do
    @kind kind
    @module module

    describe "#{inspect(module)}" do
      test "holds presets keyed by id" do
        presets = @module.all()

        assert map_size(presets) > 0
        assert Enum.reject(Map.keys(presets), &is_binary/1) == []
        assert Enum.reject(Map.values(presets), &is_binary(&1[:name])) == []
      end

      test "is what the facade finds for #{kind}" do
        assert Enum.reject(@module.all(), fn {id, preset} ->
                 Presets.find_preset_by_id(@kind, id) == preset
               end) == []
      end

      test "is what take/2 returns for #{kind}, in the order asked" do
        ids = @module.all() |> Map.keys() |> Enum.sort(:desc)

        assert Presets.take(@kind, ids) == Enum.map(ids, &{&1, Map.fetch!(@module.all(), &1)})
      end
    end
  end

  test "the per-kind getters are the kind modules' catalogues" do
    for {_kind, module, getter} <- @kinds do
      assert getter.() == module.all()
    end
  end

  test "an unknown kind or id finds nothing" do
    assert Presets.find_preset_by_id(:no_such_kind, "gradient_1") == nil
    assert Presets.find_preset_by_id(:gradient, "gradient_999") == nil
    assert Presets.take(:gradient, ["gradient_999"]) == []
  end

  describe "Presets.Accents" do
    test "holds the nine accents, each a name and a lower-case #rrggbb colour" do
      accents = Accents.all()

      assert Enum.sort(Map.keys(accents)) ==
               ~w(cobalt ember emerald graphite indigo rose teal tymeslot violet)

      assert Enum.reject(Map.values(accents), fn accent ->
               is_binary(accent.name) and accent.color =~ ~r/\A#[0-9a-f]{6}\z/
             end) == []
    end

    test "is what the facade finds for :accent" do
      assert Enum.reject(Accents.all(), fn {id, preset} ->
               Presets.find_preset_by_id(:accent, id) == preset
             end) == []
    end
  end

  describe "the tones" do
    @tones ~w(neutral cool warm)

    test "are light schemes carrying a dark set" do
      assert Enum.reject(@tones, fn id ->
               match?(%{mode: :light, colors: _, dark_colors: _}, ColourSchemes.all()[id])
             end) == []
    end

    test "read on their own card and canvas in both sets, before any accent" do
      failures =
        for id <- @tones,
            {set, c} <- [
              light: ColourSchemes.all()[id].colors,
              dark: ColourSchemes.all()[id].dark_colors
            ],
            problem <- [
              Colour.contrast_ratio(c.text, c.surface) >= 7.0 || :text,
              Colour.contrast_ratio(c.text_secondary, c.surface) >= 4.5 || :text_secondary,
              Colour.contrast_ratio(c.text_secondary, c.background) >= 4.5 ||
                :text_secondary_on_canvas,
              Colour.contrast_ratio(c.primary, c.surface) >= 4.5 || :primary
            ],
            problem != true,
            do: {id, set, problem}

      assert failures == []
    end
  end

  describe "Folio's schemes" do
    @folio_schemes ~w(ivory sage harbour blush dusk ink)

    test "are four light and two dark schemes, none carrying a dark set" do
      modes = Map.new(@folio_schemes, &{&1, ColourSchemes.all()[&1][:mode]})

      assert modes == %{
               "ivory" => :light,
               "sage" => :light,
               "harbour" => :light,
               "blush" => :light,
               "dusk" => :dark,
               "ink" => :dark
             }

      assert Enum.filter(@folio_schemes, &Map.has_key?(ColourSchemes.all()[&1], :dark_colors)) ==
               []
    end

    test "each sets every palette colour as a lower-case #rrggbb" do
      keys = ~w(accent background primary primary_hover secondary surface text text_secondary)a

      failures =
        for id <- @folio_schemes,
            colors = ColourSchemes.all()[id].colors,
            Enum.sort(Map.keys(colors)) != keys or
              not Enum.all?(Map.values(colors), &Regex.match?(~r/\A#[0-9a-f]{6}\z/, &1)),
            do: id

      assert failures == []
    end

    test "read on their own card and canvas" do
      failures =
        for id <- @folio_schemes,
            c = ColourSchemes.all()[id].colors,
            problem <- [
              Colour.contrast_ratio(c.text, c.surface) >= 7.0 || :text,
              Colour.contrast_ratio(c.text_secondary, c.surface) >= 4.5 || :text_secondary,
              Colour.contrast_ratio(c.text_secondary, c.background) >= 4.5 ||
                :text_secondary_on_canvas,
              Colour.contrast_ratio(c.primary, c.surface) >= 4.5 || :primary,
              Colour.contrast_ratio(c.primary_hover, c.surface) >= 4.5 || :primary_hover
            ],
            problem != true,
            do: {id, problem}

      assert failures == []
    end
  end

  describe "Presets.Fonts" do
    test "holds the seven font choices, each with a name" do
      assert Enum.sort(Map.keys(Fonts.all())) ==
               ~w(classic editorial inter literary plex quiet system)

      assert Enum.reject(Map.values(Fonts.all()), &is_binary(&1.name)) == []
    end

    test "is what the facade finds for :font" do
      assert Enum.reject(Fonts.all(), fn {id, preset} ->
               Presets.find_preset_by_id(:font, id) == preset
             end) == []
    end
  end
end
