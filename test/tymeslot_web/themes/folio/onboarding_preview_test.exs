defmodule TymeslotWeb.Themes.Folio.OnboardingPreviewTest do
  @moduledoc """
  Folio's preview in the onboarding wizard: the thumbnail tinted with the
  primary, and the card around the shared header with its cover strip, the
  times and a Book button whose ink reads on the primary.
  """
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Tymeslot.Availability.WeekPreview
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Folio.OnboardingPreview
  alias TymeslotWeb.Themes.Folio.Theme

  @week %{
    state: :ready,
    preview: %WeekPreview{
      days: [%{date: ~D[2026-11-03], slots: ["09:00"], busy: []}],
      slot_count: 1,
      first_busy: nil
    }
  }

  defp card(colors) do
    assigns = %{colors: colors, week: @week}

    rendered_to_string(~H"""
    <PreviewParts.theme_preview
      theme_module={Theme}
      variant={:card}
      colors={@colors}
      week={@week}
      today={~D[2026-11-03]}
    >
      <:header>
        <p id="shared-header">Ada Lovelace</p>
      </:header>
    </PreviewParts.theme_preview>
    """)
  end

  defp book_button_style(html) do
    [style] =
      Regex.run(~r/<button[^>]*style="([^"]*)"[^>]*>\s*Book/s, html, capture: :all_but_first)

    style
  end

  test "the theme draws its own preview, not the generic mock" do
    assigns = %{variant: :thumbnail, primary: "#123456"}

    assert rendered_to_string(Theme.onboarding_preview(assigns)) ==
             rendered_to_string(OnboardingPreview.render(assigns))
  end

  test "the thumbnail is tinted with the primary" do
    html = render_component(&OnboardingPreview.render/1, variant: :thumbnail, primary: "#123456")

    assert html =~ "#123456"
    assert html =~ "data-folio-cover"
  end

  test "the card draws the cover strip, the shared header, the times and Book" do
    html = card(%{primary: "#b4532a", accent: "#a0612f", surface: "#fffdf9", text: "#1f1b16"})

    assert html =~ "data-folio-cover"
    assert html =~ ~s(id="shared-header")
    assert html =~ "09:00 AM"
    assert html =~ "Book"
  end

  test "the Book button's ink reads on a light primary and on a gold one" do
    light = card(%{primary: "#b4532a", background: "#faf7f2", text: "#1f1b16"})
    gold = card(%{primary: "#e0b04a", background: "#111315", text: "#f2f2f0"})

    assert book_button_style(light) =~ "color: #ffffff"
    assert book_button_style(gold) =~ "color: #111315"
  end
end
