defmodule TymeslotWeb.OnboardingLive.ChooseThemeStepTest do
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Phoenix.HTML
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias TymeslotWeb.OnboardingLive.ChooseThemeStep
  alias TymeslotWeb.OnboardingLive.ThemeHandlers
  alias TymeslotWeb.Themes.Quill.Theme, as: Quill
  alias TymeslotWeb.Themes.Rhythm.Theme, as: Rhythm

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
      choices: choices,
      headline_form: ThemeHandlers.headline_form(nil)
    )
  end

  defp thumbnail_tag(html, id) do
    [tag] =
      Regex.run(
        ~r/<button[^>]*phx-value-theme="#{id}"[^>]*data-testid="theme-thumbnail"[^>]*>/,
        html
      )

    tag
  end

  defp escape(text), do: text |> HTML.html_escape() |> HTML.safe_to_string()

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
    assert html =~ ~s(>Kobalt</span>)
    # A name the catalogue has no translation for, here the brand, stays as given.
    assert swatch_tag(html, "tymeslot") =~ ~s(aria-label="Tymeslot")
  end

  test "marks the choice the stored setting holds" do
    html = render_step(@choices, %{"color_scheme" => "ay"})

    assert swatch_tag(html, "ay") =~ "ring-turquoise-200"
    refute swatch_tag(html, "bee") =~ "ring-turquoise-200"
  end

  describe "the theme picker" do
    test "shows every offered theme's look, in the pickers' order" do
      html = render_step(nil)

      assert Regex.scan(
               ~r/<button[^>]*phx-value-theme="([^"]+)"[^>]*data-testid="theme-thumbnail"/,
               html,
               capture: :all_but_first
             ) == [["1"], ["2"]]

      assert thumbnail_tag(html, "1") =~ ~s(phx-click="select_theme")
    end

    test "marks the organiser's current theme" do
      html = render_step(nil)

      assert thumbnail_tag(html, "1") =~ ~s(aria-pressed="true")
      assert thumbnail_tag(html, "2") =~ ~s(aria-pressed="false")
    end

    test "offers no choice by description" do
      html = render_step(nil)

      refute html =~ ~s(data-testid="theme-story")
      refute html =~ "Which of these sounds like you?"
      refute html =~ escape(Quill.story())
      refute html =~ escape(Rhythm.story())
      refute html =~ "show_theme_stories"
      refute html =~ "show_all_themes"
    end

    test "offers no separate preview: the stage shows the page" do
      html = render_step(@choices)

      refute html =~ ~s(phx-click="preview_booking_page")
      refute html =~ "Preview booking page"
    end

    test "leaves the colour row below it" do
      html = render_step(@choices)

      assert html =~ ~s(data-testid="theme-thumbnail")
      assert html =~ "Colour scheme"
    end
  end
end
