defmodule TymeslotWeb.OnboardingLive.ChooseThemeStepTest do
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias TymeslotWeb.OnboardingLive.ChooseThemeStep

  @choices %{
    group: :palette,
    field: "scheme",
    setting: "color_scheme",
    choices: [
      %{value: "bee", name: "Bee", swatch: "#bbbbbb"},
      %{value: "ay", name: "Ay", swatch: "#aaaaaa"}
    ]
  }

  defp render_step(choices, settings \\ %{}) do
    render_component(&ChooseThemeStep.choose_theme_step/1,
      profile: %{booking_theme: "1"},
      theme_options: [{"Quill", "1"}, {"Rhythm", "2"}],
      theme_customization: %ThemeCustomizationSchema{theme_id: "1", settings: settings},
      choices: choices
    )
  end

  defp swatch_tag(html, value) do
    [tag] = Regex.run(~r/<button[^>]*phx-value-choice="#{value}"[^>]*>/, html)
    tag
  end

  test "hides the colour row when the theme offers no choices" do
    html = render_step(nil)

    assert html =~ "Your booking theme"
    refute html =~ "Colour scheme"
    refute html =~ "select_onboarding_choice"
  end

  test "draws the spec's choices in its order, each named and tinted" do
    html = render_step(@choices)

    assert Regex.scan(~r/phx-value-choice="([^"]+)"/, html, capture: :all_but_first) ==
             [["bee"], ["ay"]]

    assert swatch_tag(html, "bee") =~ ~s(aria-label="Bee")
    assert swatch_tag(html, "bee") =~ "background: #bbbbbb;"
  end

  test "names each choice in the visitor's language, as the dashboard does" do
    Gettext.put_locale(TymeslotWeb.Gettext, "de")

    html =
      render_step(%{
        @choices
        | choices: [
            %{value: "cobalt", name: "Cobalt", swatch: "#2563eb"},
            %{value: "tymeslot", name: "Tymeslot", swatch: "#0891b2"}
          ]
      })

    assert swatch_tag(html, "cobalt") =~ ~s(aria-label="Kobalt")
    assert swatch_tag(html, "cobalt") =~ ~s(title="Kobalt")
    # A name the catalogue has no translation for, here the brand, stays as given.
    assert swatch_tag(html, "tymeslot") =~ ~s(aria-label="Tymeslot")
  end

  test "marks the choice the stored setting holds" do
    html = render_step(@choices, %{"color_scheme" => "ay"})

    assert swatch_tag(html, "ay") =~ "ring-turquoise-200"
    refute swatch_tag(html, "bee") =~ "ring-turquoise-200"
  end
end
