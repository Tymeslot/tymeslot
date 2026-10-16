defmodule TymeslotWeb.OnboardingLive.ChooseThemeStepTest do
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Phoenix.HTML
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias TymeslotWeb.OnboardingLive.ChooseThemeStep
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

  defp render_step(choices, settings \\ %{}, picker \\ :stories) do
    render_component(&ChooseThemeStep.choose_theme_step/1,
      profile: %{booking_theme: "1"},
      theme_options: [{"Quill", "1"}, {"Rhythm", "2"}],
      theme_customization: %ThemeCustomizationSchema{theme_id: "1", settings: settings},
      choices: choices,
      picker: picker
    )
  end

  defp story_tag(html, id) do
    [tag] =
      Regex.run(~r/<button[^>]*phx-value-theme="#{id}"[^>]*data-testid="theme-story"[^>]*>/, html)

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
    assert swatch_tag(html, "cobalt") =~ ~s(title="Kobalt")
    # A name the catalogue has no translation for, here the brand, stays as given.
    assert swatch_tag(html, "tymeslot") =~ ~s(aria-label="Tymeslot")
  end

  test "marks the choice the stored setting holds" do
    html = render_step(@choices, %{"color_scheme" => "ay"})

    assert swatch_tag(html, "ay") =~ "ring-turquoise-200"
    refute swatch_tag(html, "bee") =~ "ring-turquoise-200"
  end

  describe "the stories" do
    test "ask which one sounds like the organiser, one per offered theme, in the pickers' order" do
      html = render_step(nil)

      assert html =~ "Which of these sounds like you?"

      assert Regex.scan(
               ~r/<button[^>]*phx-value-theme="([^"]+)"[^>]*data-testid="theme-story"/,
               html,
               capture: :all_but_first
             ) == [["1"], ["2"]]

      assert story_tag(html, "1") =~ ~s(phx-click="select_theme")
      assert html =~ escape(Quill.story())
      assert html =~ escape(Rhythm.story())
    end

    test "mark the organiser's current theme" do
      html = render_step(nil)

      assert story_tag(html, "1") =~ ~s(aria-pressed="true")
      assert story_tag(html, "2") =~ ~s(aria-pressed="false")
    end

    test "are told in the organiser's language" do
      english = Quill.story()
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      german = Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_appearance", english)

      assert german != english
      assert render_step(nil) =~ escape(german)
    end

    test "keep every theme's look one click away" do
      stories = render_step(nil)

      assert stories =~ ~s(phx-click="show_all_themes")
      assert stories =~ "Show all themes"
      refute stories =~ "Choose by description instead"

      all = render_step(nil, %{}, :all)

      refute all =~ ~s(data-testid="theme-story")
      refute all =~ "Which of these sounds like you?"
      assert all =~ ~s(phx-value-theme="2")
      assert all =~ ~s(phx-click="show_theme_stories")
      assert all =~ "Choose by description instead"
    end

    test "leave the colour row below them" do
      html = render_step(@choices)

      assert html =~ "Which of these sounds like you?"
      assert html =~ "Colour scheme"
    end
  end
end
