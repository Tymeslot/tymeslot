defmodule Tymeslot.ThemeCustomizations.SpecsTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.Test.ShowcaseThemeSpec
  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.ThemeCustomizations.RhythmSpec
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Themes.Catalog

  @known_kinds [:gradient, :color, :image, :video]

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

  # A group that reads what the groups before it produced: it copies the
  # palette's canvas into a variable of its own. Declared after the palette it
  # sees the canvas; declared before, it sees nothing.
  defmodule EchoOption do
    @moduledoc false
    @behaviour Tymeslot.ThemeCustomizations.OptionGroup

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def types, do: %{}

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def changeset(changeset, _attrs, _group), do: changeset

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def changes(_field, _value, _group), do: :error

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def tokens(_settings, _overrides, %{vars: vars} = acc, _group) do
      case vars do
        %{"--theme-canvas" => canvas} -> %{acc | vars: Map.put(vars, "--echo-canvas", canvas)}
        _no_canvas -> acc
      end
    end
  end

  defmodule EchoAfterPaletteSpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    alias Tymeslot.ThemeCustomizations.Options.Palette
    alias Tymeslot.ThemeCustomizations.SpecsTest.EchoOption

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups,
      do: [
        %{key: :palette, module: Palette, schemes: ["default"]},
        %{key: :echo, module: EchoOption}
      ]

    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: %{color_scheme: "default"}
  end

  defmodule EchoBeforePaletteSpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    alias Tymeslot.ThemeCustomizations.Options.Palette
    alias Tymeslot.ThemeCustomizations.SpecsTest.EchoOption

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups,
      do: [
        %{key: :echo, module: EchoOption},
        %{key: :palette, module: Palette, schemes: ["default"]}
      ]

    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: %{color_scheme: "default"}
  end

  # A theme that offers no video, like the minimalist theme will, and an
  # option group of its own.
  defmodule StillSpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    alias Tymeslot.ThemeCustomizations.Options.Background
    alias Tymeslot.ThemeCustomizations.SpecsTest.TaglineOption

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
  end

  describe "setting_types/1" do
    test "merges every group module's types" do
      assert Specs.setting_types(StillSpec) == Map.put(Background.types(), :tagline, :string)
    end
  end

  # A group that declares a file but takes no uploads into it.
  defmodule StampOption do
    @moduledoc false
    @behaviour Tymeslot.ThemeCustomizations.OptionGroup

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def types, do: %{stamp_path: :string}
    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def changeset(changeset, _attrs, _group), do: changeset
    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def changes(_field, _value, _group), do: :error
    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def asset_fields(_group), do: [stamp_path: :image]
  end

  defmodule StampSpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups, do: [%{key: :stamp, module: StampOption}]
    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: %{}
  end

  # A group whose upload_changes/3 also names a background setting, which
  # `Specs.upload_changes/3` must drop: an upload may only change the
  # settings of the group that owns its field.
  defmodule LeakyOption do
    @moduledoc false
    @behaviour Tymeslot.ThemeCustomizations.OptionGroup

    import Ecto.Changeset

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def types, do: %{leaky_path: :string}
    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def changeset(changeset, attrs, _group), do: cast(changeset, attrs, [:leaky_path])
    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def changes(_field, _value, _group), do: :error
    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def asset_fields(_group), do: [leaky_path: :image]
    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def upload_changes(:leaky_path, path, _group),
      do: %{"leaky_path" => path, "background_type" => "color"}
  end

  defmodule LeakySpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    alias Tymeslot.ThemeCustomizations.QuillSpec
    alias Tymeslot.ThemeCustomizations.SpecsTest.LeakyOption

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups, do: QuillSpec.option_groups() ++ [%{key: :leaky, module: LeakyOption}]
    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: QuillSpec.defaults()
  end

  # A spec with no option group at all.
  defmodule BareSpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups, do: []

    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: %{}
  end

  # An accent group whose preset list a later release shortened.
  defmodule AccentSpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    alias Tymeslot.ThemeCustomizations.Options.Accent

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups,
      do: [%{key: :accent, module: Accent, presets: ~w(tymeslot cobalt), default: "tymeslot"}]

    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: %{accent: "tymeslot"}
  end

  describe "settings/2" do
    test "fills what is not stored from the spec's defaults" do
      assert Specs.settings(QuillSpec, %{}) == %{
               "color_scheme" => "default",
               "background_type" => "gradient",
               "background_value" => "gradient_1"
             }
    end

    test "keeps stored settings every group accepts" do
      stored = %{
        "color_scheme" => "ocean",
        "background_type" => "video",
        "background_value" => "preset:space"
      }

      assert Specs.settings(QuillSpec, stored) == stored
    end

    test "gives a group whose stored value it no longer accepts its defaults, and no other group" do
      stored = %{
        "color_scheme" => "ocean",
        "background_type" => "gradient",
        "background_value" => "gradient_99"
      }

      assert Specs.settings(QuillSpec, stored) == %{
               "color_scheme" => "ocean",
               "background_type" => "gradient",
               "background_value" => "gradient_1"
             }
    end

    test "starts a group the row was saved without from its defaults" do
      assert Specs.settings(QuillSpec, %{"color_scheme" => "ocean"}) == %{
               "color_scheme" => "ocean",
               "background_type" => "gradient",
               "background_value" => "gradient_1"
             }
    end

    # 1.25.0 accepted an uploaded image with no `background_value`; the
    # spec's default preset must not stand in for it and hide the upload.
    test "keeps an upload stored without a background value" do
      stored = %{
        "color_scheme" => "default",
        "background_type" => "image",
        "background_image_path" => "themes/2/5/images/photo.jpg"
      }

      assert Specs.settings(RhythmSpec, stored) == stored
    end

    test "drops a kind the theme stopped offering, with the upload it named" do
      stored = %{
        "background_type" => "video",
        "background_value" => "custom",
        "background_video_path" => "themes/1/5/videos/clip.mp4"
      }

      assert Specs.settings(StillSpec, stored) == %{
               "background_type" => "gradient",
               "background_value" => "gradient_1"
             }
    end

    test "drops a refused setting that has no default" do
      assert Specs.settings(StillSpec, %{"tagline" => String.duplicate("x", 11)}) == %{
               "background_type" => "gradient",
               "background_value" => "gradient_1"
             }
    end

    test "falls back for a preset the group no longer lists, even one its choice/2 would hide" do
      assert Specs.settings(AccentSpec, %{"accent" => "ember"}) == %{"accent" => "tymeslot"}
      assert Specs.settings(AccentSpec, %{"accent" => "cobalt"}) == %{"accent" => "cobalt"}
    end

    test "reads settings as a save stores them, normalised" do
      assert Specs.settings(AccentSpec, %{"accent" => "#AABBCC"}) == %{"accent" => "#aabbcc"}
    end

    test "drops keys no group declares" do
      refute Map.has_key?(Specs.settings(QuillSpec, %{"legacy_option" => "x"}), "legacy_option")
    end
  end

  # Validates `attrs` over `stored` settings, the way a save does.
  defp validate_over(spec, stored, attrs) do
    data = Map.new(stored, fn {key, value} -> {String.to_existing_atom(key), value} end)
    {data, Specs.setting_types(spec)} |> Changeset.change() |> spec.changeset(attrs)
  end

  defp saved_settings(changeset) do
    changeset
    |> Changeset.apply_changes()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  describe "media/2" do
    test "merges what every group resolves, in declaration order" do
      settings = %{
        "color_scheme" => "neutral",
        "background_type" => "color",
        "background_value" => "#123456",
        "logo_path" => "themes/1/9/images/logo.png",
        "cover_value" => "custom",
        "cover_path" => "themes/1/9/images/cover.png"
      }

      assert Specs.media(ShowcaseThemeSpec, settings) == %{
               background: %{kind: :color, color: "#123456"},
               logo: %{src: "/uploads/themes/1/9/images/logo.png"},
               cover: %{src: "/uploads/themes/1/9/images/cover.png", preset: nil}
             }
    end

    test "leaves out what resolves to nothing" do
      assert Specs.media(ShowcaseThemeSpec, %{
               "background_type" => "gradient",
               "background_value" => "gradient_999",
               "cover_value" => "custom"
             }) == %{}
    end
  end

  describe "tokens/3" do
    test "carries the spec's media" do
      settings = %{
        "color_scheme" => "neutral",
        "background_type" => "color",
        "background_value" => "#123456",
        "logo_path" => "themes/1/9/images/logo.png"
      }

      assert %Tokens{media: media, vars: vars} = Specs.tokens(ShowcaseThemeSpec, settings, %{})
      assert media == Specs.media(ShowcaseThemeSpec, settings)
      assert vars["--theme-background"] == "#123456"
      assert vars["--theme-primary"] == "#07819e"
    end

    # The groups after the palette read what it produced: the background's
    # canvas fallback and the accent's card. A palette stored as a seed alone
    # must feed them as a named scheme does.
    test "a palette stored as a seed alone feeds the groups after it" do
      settings = %{
        "custom_palette_seed" => "#b4532a",
        "accent" => "tymeslot",
        "background_type" => "image",
        "background_value" => "preset:ocean-sunset"
      }

      %Tokens{vars: vars, dark_vars: dark_vars} = Specs.tokens(ShowcaseThemeSpec, settings, %{})

      assert vars["--theme-canvas"]
      assert vars["--theme-background"] == "var(--theme-canvas)"
      assert dark_vars["--theme-canvas"]

      # The Tymeslot accent, #0891b2, does not read as text on the light
      # derivation's card, so it is written fitted, never as it stands.
      assert vars["--theme-primary"]
      refute vars["--theme-primary"] == "#0891b2"
    end

    test "is the tokens use Spec generates" do
      settings = %{"background_type" => "color", "background_value" => "#123456"}

      assert ShowcaseThemeSpec.tokens(settings, %{}) ==
               Specs.tokens(ShowcaseThemeSpec, settings, %{})

      assert ShowcaseThemeSpec.tokens(settings, %{}).media == %{
               background: %{kind: :color, color: "#123456"},
               cover: %{
                 src: Presets.find_preset_by_id(:cover, "elegant-still-life").src,
                 preset: "elegant-still-life"
               }
             }
    end

    test "without a palette group, emits no palette variables, even over a stored seed" do
      settings = %{
        "color_scheme" => "default",
        "custom_palette_seed" => "#336699",
        "background_type" => "color",
        "background_value" => "#123456"
      }

      assert Specs.tokens(StillSpec, settings, %{primary_color: "#ff0000"}) == %Tokens{
               vars: %{"--theme-background" => "#123456"},
               dark_vars: %{},
               media: %{background: %{kind: :color, color: "#123456"}}
             }
    end

    test "without any group, is empty" do
      settings = %{"custom_palette_seed" => "#336699", "background_type" => "color"}

      assert Specs.tokens(BareSpec, settings, %{}) == %Tokens{}
      assert BareSpec.tokens(settings, %{}) == %Tokens{}
    end

    test "folds every group's tokens/4 in declaration order" do
      settings = %{"color_scheme" => "default"}

      assert Specs.tokens(EchoAfterPaletteSpec, settings, %{}).vars["--echo-canvas"] == "#0f172a"

      refute Map.has_key?(
               Specs.tokens(EchoBeforePaletteSpec, settings, %{}).vars,
               "--echo-canvas"
             )
    end

    test "a group's tokens/4 changes only what it returns" do
      settings = %{"color_scheme" => "default"}

      echoed = Specs.tokens(EchoAfterPaletteSpec, settings, %{})
      plain = Specs.tokens(EchoBeforePaletteSpec, settings, %{})

      assert Map.delete(echoed.vars, "--echo-canvas") == plain.vars
      assert echoed.dark_vars == plain.dark_vars
    end
  end

  describe "OptionGroup.tokens/4" do
    test "hands back what it was given for a group whose module has no tokens/4" do
      acc = %{vars: %{"--theme-primary" => "#123456"}, dark_vars: %{"--theme-text" => "#ffffff"}}

      assert OptionGroup.tokens(%{}, %{}, acc, %{key: :tagline, module: TaglineOption, max: 10}) ==
               acc
    end

    test "is the group module's tokens/4 where it has one" do
      acc = %{vars: %{"--theme-canvas" => "#abcdef"}, dark_vars: %{}}

      assert OptionGroup.tokens(%{}, %{}, acc, %{key: :echo, module: EchoOption}) == %{
               vars: %{"--theme-canvas" => "#abcdef", "--echo-canvas" => "#abcdef"},
               dark_vars: %{}
             }
    end
  end

  describe "group/2" do
    test "finds a spec's group by its module" do
      assert %{key: :tagline, max: 10} = Specs.group(StillSpec, TaglineOption)
      assert Specs.group(QuillSpec, TaglineOption) == nil
    end
  end

  describe "for_theme/1" do
    for {_key, theme} <- Catalog.all() do
      test "returns #{theme.name}'s spec" do
        assert Specs.for_theme(unquote(theme.id)) == unquote(theme.customization_spec)
      end
    end

    test "falls back to the default theme's spec for an unknown id" do
      assert Specs.for_theme("no-such-theme") == Catalog.default().customization_spec
    end
  end

  describe "supports_background?/2" do
    test "is false for a kind the spec does not declare" do
      refute Specs.supports_background?(StillSpec, :video)
      assert Specs.supports_background?(StillSpec, :gradient)
    end

    # Every catalogue theme, so a new one is checked the moment it is listed.
    for {_key, theme} <- Catalog.all() do
      test "#{theme.name} declares only known background kinds, each once" do
        kinds = Specs.background_kinds(unquote(theme.customization_spec))

        assert kinds == Enum.uniq(kinds)
        assert kinds -- @known_kinds == []
      end
    end
  end

  describe "upload_group/2" do
    test "finds the group that owns an asset field, with the field's kind" do
      assert {:ok, %{key: :logo}, :image} = Specs.upload_group(ShowcaseThemeSpec, :logo_path)
      assert {:ok, %{key: :cover}, :image} = Specs.upload_group(ShowcaseThemeSpec, :cover_path)

      assert {:ok, %{key: :background}, :video} =
               Specs.upload_group(ShowcaseThemeSpec, :background_video_path)
    end

    test "is :error for a field no group declares" do
      assert Specs.upload_group(QuillSpec, :logo_path) == :error
    end

    test "is :error for a field whose group takes no uploads" do
      assert StampSpec.asset_fields() == [stamp_path: :image]
      assert Specs.upload_group(StampSpec, :stamp_path) == :error
    end
  end

  describe "upload_changes/3" do
    test "keeps an upload to the settings of the group that owns the field" do
      {:ok, group, :image} = Specs.upload_group(LeakySpec, :leaky_path)

      assert Specs.upload_changes(group, :leaky_path, "themes/1/9/images/a.png") ==
               %{"leaky_path" => "themes/1/9/images/a.png"}
    end

    test "a logo upload saves the logo path and nothing else" do
      {:ok, group, :image} = Specs.upload_group(ShowcaseThemeSpec, :logo_path)

      assert Specs.upload_changes(group, :logo_path, "themes/1/9/images/a-logo.png") ==
               %{"logo_path" => "themes/1/9/images/a-logo.png"}
    end

    test "a logo upload saves beside the stored background, leaving it as it was" do
      stored = %{
        "color_scheme" => "default",
        "background_type" => "image",
        "background_value" => "custom",
        "background_image_path" => "themes/1/9/images/a-bg.png"
      }

      {:ok, group, :image} = Specs.upload_group(ShowcaseThemeSpec, :logo_path)
      changes = Specs.upload_changes(group, :logo_path, "themes/1/9/images/b-logo.png")
      changeset = validate_over(ShowcaseThemeSpec, stored, changes)

      assert changeset.valid?

      assert saved_settings(changeset) ==
               Map.put(stored, "logo_path", "themes/1/9/images/b-logo.png")
    end

    test "a background upload keeps every change the background makes" do
      {:ok, group, :image} = Specs.upload_group(QuillSpec, :background_image_path)

      assert Specs.upload_changes(group, :background_image_path, "themes/1/1/images/a.png") ==
               %{
                 "background_type" => "image",
                 "background_value" => "custom",
                 "background_image_path" => "themes/1/1/images/a.png",
                 "background_video_path" => nil
               }
    end
  end

  describe "asset fields and the transcoder" do
    # Each video's processing state lives under its own field and gets a
    # transcoding job of its own, so a theme may offer several.
    test "a catalogued spec may declare several video fields, each an upload of its own" do
      {:ok, spec} = Catalog.customization_spec("99")

      videos = for {field, :video} <- spec.asset_fields(), do: field
      assert videos == [:fixture_intro_clip_path, :fixture_outro_clip_path]

      assert Enum.reject(videos, &match?({:ok, _group, :video}, Specs.upload_group(spec, &1))) ==
               []
    end
  end
end
