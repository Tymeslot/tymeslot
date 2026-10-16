defmodule Tymeslot.ThemeCustomizations.SpecTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Cover
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.ThemeCustomizations.RhythmSpec
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Themes.Catalog

  # An option group no shipped theme has: shared code must handle it through
  # its module alone.
  defmodule TaglineOption do
    @moduledoc false
    @behaviour Tymeslot.ThemeCustomizations.OptionGroup

    import Ecto.Changeset

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def types, do: %{tagline: :string}

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def changeset(changeset, attrs, group),
      do: changeset |> cast(attrs, [:tagline]) |> validate_length(:tagline, max: group.max)

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def changes("text", value, _group), do: {:ok, %{"tagline" => value}}
    def changes(_field, _value, _group), do: :error
  end

  # A theme that offers no video, like the minimalist theme will, and an
  # option group of its own.
  defmodule StillSpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    alias Tymeslot.ThemeCustomizations.Options.Background
    alias Tymeslot.ThemeCustomizations.SpecTest.TaglineOption
    alias Tymeslot.ThemeCustomizations.Tokens

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups,
      do: [
        %{
          key: :background,
          module: Background,
          kinds: [:gradient, :color, :image],
          gradients: ["gradient_1"],
          images: ["preset:ocean-sunset"]
        },
        %{key: :tagline, module: TaglineOption, max: 10}
      ]

    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: %{background_type: "gradient", background_value: "gradient_1"}

    @impl Tymeslot.ThemeCustomizations.Spec
    def tokens(_settings, _overrides), do: %Tokens{}
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)

  defp validate(spec, attrs) do
    {%{}, Specs.setting_types(spec)} |> Changeset.change() |> spec.changeset(attrs)
  end

  @list_keys %{gradient: :gradients, image: :images, video: :videos}

  # Every id a group lists that the catalogue does not ship, as {list, id}.
  # An empty list is not a problem in itself: a seed-only palette lists no
  # schemes (its defaults then fail "defaults pass its own changeset" unless
  # they store a seed), and an upload-only image kind lists no images.
  defp unknown_presets(spec) do
    Enum.flat_map(spec.option_groups(), fn
      %{module: Palette} = group ->
        unknown(:schemes, group.schemes, Palette.schemes(group))

      %{module: Background, kinds: kinds} = group ->
        Enum.flat_map(kinds -- [:color], fn kind ->
          key = Map.fetch!(@list_keys, kind)
          unknown(key, Map.get(group, key, []), Background.presets(group, kind))
        end)

      %{module: Cover} = group ->
        # The default must be one of the covers the picker offers.
        unknown(:presets, group.presets, Cover.presets(group)) ++
          Enum.map([group.default] -- group.presets, &{:default, &1})

      _other_group ->
        []
    end)
  end

  defp unknown(list, ids, resolved),
    do: Enum.map(ids -- Enum.map(resolved, &elem(&1, 0)), &{list, &1})

  describe "use Spec" do
    test "the generated changeset/2 runs every group's changeset/3 with its own descriptor" do
      cs =
        validate(StillSpec, %{
          "background_type" => "video",
          "background_value" => "preset:space",
          "tagline" => String.duplicate("x", 11)
        })

      assert {"is not supported by this theme", _opts} = cs.errors[:background_type]
      assert {"should be at most %{count} character(s)", _opts} = cs.errors[:tagline]
    end

    test "the generated changeset/2 accepts what every group accepts" do
      assert validate(StillSpec, %{
               "background_type" => "color",
               "background_value" => "#123456",
               "tagline" => "Hello"
             }).valid?
    end

    test "the generated asset_fields/0 joins the groups' upload fields" do
      # Background offers only the image upload here; TaglineOption has no
      # asset_fields/1 and so contributes none.
      assert StillSpec.asset_fields() == [background_image_path: :image]
    end
  end

  describe "use Spec's check of its groups" do
    test "refuses a spec two of whose groups store the same setting" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_quoted(
            quote do
              defmodule Tymeslot.ThemeCustomizations.SpecTest.SharedSettingSpec do
                use Tymeslot.ThemeCustomizations.Spec

                alias Tymeslot.ThemeCustomizations.Options.Palette

                @impl Tymeslot.ThemeCustomizations.Spec
                def option_groups,
                  do: [
                    %{key: :palette, module: Palette, schemes: ["default"]},
                    %{key: :second_palette, module: Palette, schemes: ["forest"]}
                  ]

                @impl Tymeslot.ThemeCustomizations.Spec
                def defaults, do: %{color_scheme: "default"}
              end
            end
          )
        end

      assert error.description =~ "SharedSettingSpec"
      assert error.description =~ ":color_scheme"
      assert error.description =~ "[:palette, :second_palette]"
    end

    test "refuses a spec with two groups under the same key" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_quoted(
            quote do
              defmodule Tymeslot.ThemeCustomizations.SpecTest.SharedKeySpec do
                use Tymeslot.ThemeCustomizations.Spec

                alias Tymeslot.ThemeCustomizations.Options.Palette

                @impl Tymeslot.ThemeCustomizations.Spec
                def option_groups,
                  do: [
                    %{key: :look, module: Palette, schemes: ["default"]},
                    %{
                      key: :look,
                      module: Tymeslot.ThemeCustomizations.Options.Radius,
                      default: "soft"
                    }
                  ]

                @impl Tymeslot.ThemeCustomizations.Spec
                def defaults, do: %{color_scheme: "default", radius: "soft"}
              end
            end
          )
        end

      assert error.description =~ "SharedKeySpec"
      assert error.description =~ "option group key :look"
      refute error.description =~ ":color_scheme"
    end

    test "compiles a spec whose groups keep to settings of their own" do
      assert [{Tymeslot.ThemeCustomizations.SpecTest.SeparateSpec, _bytecode}] =
               Code.compile_quoted(
                 quote do
                   defmodule Tymeslot.ThemeCustomizations.SpecTest.SeparateSpec do
                     use Tymeslot.ThemeCustomizations.Spec

                     alias Tymeslot.ThemeCustomizations.Options.Palette

                     @impl Tymeslot.ThemeCustomizations.Spec
                     def option_groups,
                       do: [
                         %{key: :palette, module: Palette, schemes: ["default"]},
                         %{
                           key: :radius,
                           module: Tymeslot.ThemeCustomizations.Options.Radius,
                           default: "soft"
                         }
                       ]

                     @impl Tymeslot.ThemeCustomizations.Spec
                     def defaults, do: %{color_scheme: "default", radius: "soft"}
                   end
                 end
               )
    end
  end

  describe "preset lists" do
    # Every catalogue theme, so a new one is checked the moment it is listed.
    for {_key, theme} <- Catalog.all() do
      test "#{theme.name} lists only shipped presets" do
        assert unknown_presets(unquote(theme.customization_spec)) == []
      end
    end

    test "a group refuses a shipped preset it does not list" do
      cs =
        validate(StillSpec, %{"background_type" => "gradient", "background_value" => "gradient_2"})

      assert {"must be a valid gradient preset", _opts} = cs.errors[:background_value]
    end
  end

  describe "colour mode" do
    # ColourMode chooses between the palette's light and dark sets, so it only
    # works over a palette that has both: `follow_os`, a light `seed_mode` and
    # light schemes only. Each entry is a requirement the palette misses.
    for {_key, theme} <- Catalog.all() do
      test "#{theme.name} declares colour mode only over a palette with a light and a dark set" do
        assert colour_mode_shortfalls(unquote(theme.customization_spec)) == []
      end
    end

    test "the check sees a palette that misses a requirement" do
      assert colour_mode_shortfalls(__MODULE__.DarkSeedSpec) == [
               :follow_os,
               :seed_mode,
               {:scheme, "default"}
             ]
    end

    test "some catalogue theme declares colour mode, so the check has something to inspect" do
      assert Enum.any?(Catalog.all(), fn {_key, theme} ->
               Enum.any?(theme.customization_spec.option_groups(), &(&1.module == ColourMode))
             end)
    end
  end

  defmodule DarkSeedSpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    alias Tymeslot.ThemeCustomizations.Options.ColourMode
    alias Tymeslot.ThemeCustomizations.Options.Palette

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups,
      do: [
        %{key: :palette, module: Palette, schemes: ["default"]},
        %{key: :colour_mode, module: ColourMode, default: "auto"}
      ]

    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: %{color_scheme: "default", colour_mode: "auto"}
  end

  # The requirements of the palette a spec's colour mode reads, unmet; empty
  # for a spec with no colour mode.
  defp colour_mode_shortfalls(spec) do
    groups = spec.option_groups()

    if Enum.any?(groups, &(&1.module == ColourMode)) do
      palette = Enum.find(groups, &(&1.module == Palette))

      missing = [
        if(palette[:follow_os] == true, do: nil, else: :follow_os),
        if(palette[:seed_mode] == :light, do: nil, else: :seed_mode)
      ]

      Enum.reject(missing, &is_nil/1) ++
        for {id, %{mode: :dark}} <- Palette.schemes(palette), do: {:scheme, id}
    else
      []
    end
  end

  describe "defaults/0" do
    for {_key, theme} <- Catalog.all() do
      test "#{theme.name}'s default background is a kind it declares" do
        {:ok, spec} = Catalog.customization_spec(unquote(theme.id))

        case spec.defaults() do
          %{background_type: type} ->
            assert String.to_existing_atom(type) in Specs.background_kinds(spec)

          _no_background_default ->
            assert Specs.background_kinds(spec) == []
        end
      end

      test "#{theme.name}'s defaults are what an empty row reads as" do
        {:ok, spec} = Catalog.customization_spec(unquote(theme.id))

        assert Specs.settings(spec, %{}) ==
                 spec.defaults() |> stringify() |> Map.reject(fn {_k, v} -> is_nil(v) end)
      end

      test "#{theme.name}'s defaults pass its own changeset" do
        {:ok, spec} = Catalog.customization_spec(unquote(theme.id))

        assert validate(spec, stringify(spec.defaults())).valid?
      end
    end

    # A product decision per theme, pinned as such: Rhythm's identity is its
    # video, Quill's its gradient.
    test "Quill defaults to the Aurora gradient, Rhythm to its own video" do
      assert %{background_type: "gradient", background_value: "gradient_1"} = QuillSpec.defaults()

      assert %{background_type: "video", background_value: "preset:rhythm-default"} =
               RhythmSpec.defaults()
    end
  end

  describe "tokens/2" do
    test "merges the palette and background variables, the background winning" do
      tokens =
        QuillSpec.tokens(
          %{
            "color_scheme" => "default",
            "background_type" => "color",
            "background_value" => "#123456"
          },
          %{}
        )

      assert tokens.vars["--theme-primary"] == "#06b6d4"
      assert tokens.vars["--theme-background"] == "#123456"
      assert tokens.dark_vars == %{}
    end
  end

  test "asset_fields/0 names the two upload columns" do
    assert QuillSpec.asset_fields() == [
             background_image_path: :image,
             background_video_path: :video
           ]

    assert RhythmSpec.asset_fields() == QuillSpec.asset_fields()
  end
end
