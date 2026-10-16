defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.OptionPanelTest do
  @moduledoc """
  A dashboard panel offers exactly the presets its option group lists, in the
  group's order, never the whole catalogue.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  @moduletag :themes
  @moduletag :components

  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Density
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.ThemeCustomizations.Presets.ColourSchemes
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Components
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panels

  defmodule StubPanel do
    @moduledoc false
    use Phoenix.Component

    @spec render(map()) :: Phoenix.LiveView.Rendered.t()
    def render(assigns) do
      ~H"""
      <p id="stub-panel">{@group.key}</p>
      """
    end
  end

  @customization %ThemeCustomizationSchema{
    settings: %{
      "color_scheme" => "ocean",
      "background_type" => "gradient",
      "background_value" => "gradient_4"
    }
  }

  @background %{
    key: :background,
    module: Background,
    kinds: [:gradient, :image, :video],
    gradients: ["gradient_4", "gradient_2"],
    images: ["preset:ocean-sunset"],
    videos: ["preset:space"]
  }

  defp render_panel(group, extra \\ []) do
    assigns =
      Keyword.merge(
        [
          panel: Panels.for_group("1", group),
          group: group,
          customization: @customization,
          uploads: nil,
          myself: nil,
          palette_picker_open: false,
          browsing_type: "gradient",
          custom_picker_open: false
        ],
        extra
      )

    render_component(&Components.option_panel/1, assigns)
  end

  defp choices(html, field) do
    html
    |> Floki.parse_fragment!()
    |> Floki.attribute("button[phx-value-field='#{field}']", "phx-value-choice")
  end

  # A `schemes:` list is the theme's presentation order, which the dashboard
  # keeps, as onboarding does.
  test "the palette panel shows the group's schemes in the group's order" do
    html = render_panel(%{key: :palette, module: Palette, schemes: ["ocean", "forest"]})

    assert choices(html, "scheme") == ["ocean", "forest"]
  end

  test "an unselected scheme's name uses the dashboard's secondary text, not a fainter one" do
    html = render_panel(%{key: :palette, module: Palette, schemes: ["ocean", "forest"]})

    [label_class] =
      html
      |> Floki.parse_fragment!()
      |> Floki.find("button[phx-value-choice='forest'] p")
      |> Floki.attribute("class")

    assert label_class =~ "text-tymeslot-500"
    refute label_class =~ "text-tymeslot-400"
  end

  test "a scheme's dots sit on its own background, a tone's on the neutral backing" do
    html =
      render_panel(%{key: :palette, module: Palette, schemes: ~w(ocean neutral)})

    tone_html =
      render_panel(%{key: :palette, module: Palette, schemes: ~w(neutral), follow_os: true})

    backing = fn html, scheme ->
      html
      |> Floki.parse_fragment!()
      |> Floki.find("button[phx-value-choice='#{scheme}'] [data-testid='scheme-swatches']")
      |> Floki.attribute("style")
    end

    assert backing.(html, "ocean") ==
             ["background-color: #{ColourSchemes.all()["ocean"].colors.background}"]

    assert backing.(html, "neutral") ==
             ["background-color: #{ColourSchemes.all()["neutral"].colors.background}"]

    assert backing.(tone_html, "neutral") == []
  end

  test "the current-palette indicator derives a seed the way the group does" do
    seeded = %ThemeCustomizationSchema{
      settings: %{"color_scheme" => "default", "custom_palette_seed" => "#ff6b35"}
    }

    light = PaletteDerivation.derive_palette("#ff6b35", :light).colors
    dark = PaletteDerivation.derive_palette("#ff6b35", :dark).colors

    html =
      render_panel(%{key: :palette, module: Palette, schemes: ["default"], seed_mode: :light},
        customization: seeded,
        palette_picker_open: true
      )

    assert html =~ "background: #{light.secondary}"
    refute html =~ "background: #{dark.secondary}"
  end

  test "the tone schemes of a follow_os group draw different swatches" do
    html =
      render_panel(%{
        key: :palette,
        module: Palette,
        schemes: ~w(neutral cool warm),
        follow_os: true
      })

    swatches =
      for scheme <- ~w(neutral cool warm) do
        html
        |> Floki.parse_fragment!()
        |> Floki.find("button[phx-value-choice='#{scheme}'] div[style]")
        |> Floki.attribute("style")
      end

    assert Enum.all?(swatches, &(length(&1) == 3))
    assert length(Enum.uniq(swatches)) == 3
    assert swatches |> Enum.concat() |> Enum.uniq() |> length() == 9

    [neutral | _others] = swatches
    tone = ColourSchemes.all()["neutral"]

    assert neutral == [
             "background-color: #{tone.colors.background}",
             "background-color: #{tone.colors.text_secondary}",
             "background-color: #{tone.dark_colors.background}"
           ]
  end

  test "the schemes of a group without follow_os keep their primary, secondary and accent" do
    html = render_panel(%{key: :palette, module: Palette, schemes: ~w(neutral)})
    tone = ColourSchemes.all()["neutral"]

    assert html =~ "background-color: #{tone.colors.primary}"
    assert html =~ "background-color: #{tone.colors.accent}"
  end

  test "the background panel shows the group's presets of the kind being browsed" do
    assert choices(render_panel(@background), "gradient") == ["gradient_4", "gradient_2"]

    assert choices(render_panel(@background, browsing_type: "image"), "image") ==
             ["preset:ocean-sunset"]

    assert choices(render_panel(@background, browsing_type: "video"), "video") == ["preset:space"]
  end

  test "option_panel/1 renders the panel module it is given" do
    html =
      render_component(&Components.option_panel/1,
        panel: StubPanel,
        group: %{key: :tagline, module: Some.TaglineGroup}
      )

    assert html =~ ~s(<p id="stub-panel">tagline</p>)
  end

  test "the accent panel lists the group's presets in its order, named in the viewer's language" do
    group = %{key: :accent, module: Accent, presets: ~w(tymeslot cobalt), default: "tymeslot"}

    html =
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        render_panel(group, accent_picker_open: false)
      end)

    assert choices(html, "preset") == ["tymeslot", "cobalt"]
    assert html =~ "Akzentfarbe"
    assert html =~ "Kobalt"
    assert html =~ "Tymeslot"
  end

  test "the accent and font panels press the default for a stored id they do not offer" do
    accent = %{key: :accent, module: Accent, presets: ~w(tymeslot cobalt), default: "tymeslot"}
    font = %{key: :font, module: Font, presets: ~w(system inter), default: "system"}

    for {group, field, stored, default} <- [
          {accent, "preset", "nope", "tymeslot"},
          {accent, "preset", "indigo", "tymeslot"},
          {font, "font", "nope", "system"},
          {font, "font", "classic", "system"}
        ] do
      html =
        render_panel(group,
          accent_picker_open: false,
          customization: %ThemeCustomizationSchema{settings: %{"#{group.key}" => stored}}
        )

      pressed =
        html
        |> Floki.parse_fragment!()
        |> Floki.attribute(
          "button[phx-value-field='#{field}'][aria-pressed='true']",
          "phx-value-choice"
        )

      assert pressed == [default], "for #{stored}"
    end
  end

  test "the palette panel names a scheme in the viewer's language where the catalogue has it" do
    html =
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        render_panel(%{key: :palette, module: Palette, schemes: ["cool", "ocean"]})
      end)

    assert html =~ "Kühl"
    assert html =~ "Ocean Breeze"
  end

  test "the colour-mode panel offers the three modes, named in the viewer's language" do
    group = %{key: :colour_mode, module: ColourMode, default: "auto"}

    html = Gettext.with_locale(TymeslotWeb.Gettext, "de", fn -> render_panel(group) end)

    assert choices(html, "mode") == ~w(light dark auto)
    assert html =~ "Farbmodus"
    assert html =~ "Hell"
    assert html =~ "Wie Gerät"
  end

  test "the font panel names each font in the viewer's language and needs no font file" do
    group = %{key: :font, module: Font, presets: ~w(classic inter), default: "classic"}

    html = Gettext.with_locale(TymeslotWeb.Gettext, "de", fn -> render_panel(group) end)

    assert choices(html, "font") == ["classic", "inter"]
    assert html =~ "Schrift"
    assert html =~ "Klassisch"
    assert html =~ "Inter"
    # Without the booking page's font CSS the label falls back to the
    # dashboard's own font.
    assert html =~ "var(--font-heading-classic, inherit)"
  end

  test "the radius and density panels name their choices in the viewer's language" do
    radius = %{key: :radius, module: Radius, default: "soft"}
    density = %{key: :density, module: Density, default: "comfortable"}

    {radius_html, density_html} =
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        {render_panel(radius), render_panel(density)}
      end)

    assert choices(radius_html, "radius") == ~w(sharp soft round)
    assert radius_html =~ "Ecken"
    assert radius_html =~ "Rund"
    assert choices(density_html, "density") == ~w(comfortable compact)
    assert density_html =~ "Abstände"
    assert density_html =~ "Kompakt"
  end
end
