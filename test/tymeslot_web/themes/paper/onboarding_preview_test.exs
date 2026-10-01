defmodule TymeslotWeb.Themes.Paper.OnboardingPreviewTest do
  @moduledoc """
  Paper as the onboarding wizard draws it: its own thumbnail and card, not
  the generic mock, tinted with the organiser's accent, with the meeting's
  details beside a month calendar and a column of times.
  """
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]

  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Paper.Theme

  @slots [
    %{label: "9:00", state: :default, check: false},
    %{label: "9:30", state: :filled, check: true}
  ]

  test "the thumbnail is Paper's own, tinted with the primary colour" do
    html =
      render_component(&PreviewParts.theme_preview/1,
        theme_module: Theme,
        variant: :thumbnail,
        primary: "#2563eb"
      )

    assert html =~ ~s(data-preview="paper")
    assert html =~ "#2563eb"
  end

  test "the card puts the calendar beside a column of times, under the shared header" do
    assigns = %{slots: @slots}

    html =
      rendered_to_string(~H"""
      <PreviewParts.theme_preview
        theme_module={Theme}
        variant={:card}
        colors={%{primary: "#2563eb", surface: "#ffffff", text: "#111111"}}
        slots={@slots}
      >
        <:header>
          <p id="shared-header">Ada Lovelace</p>
        </:header>
      </PreviewParts.theme_preview>
      """)

    doc = Floki.parse_fragment!(html)

    assert [_card] = Floki.find(doc, "[data-preview='paper']")
    assert [_header] = Floki.find(doc, "#shared-header")
    assert [_calendar] = Floki.find(doc, "[data-preview-part='calendar'].grid-cols-7")
    assert [_times] = Floki.find(doc, "[data-preview-part='times']")
    assert html =~ "9:30"
    assert [book] = Floki.find(doc, "[data-preview='paper'] > button")
    assert Floki.text(book) =~ "Book"
    assert [style] = Floki.attribute(book, "style")
    assert style =~ "background: #2563eb;"
  end

  test "the card's edge follows the text colour, so a dark card gets a light edge" do
    assigns = %{slots: @slots}

    html =
      rendered_to_string(~H"""
      <PreviewParts.theme_preview
        theme_module={Theme}
        variant={:card}
        colors={%{primary: "#0891b2", surface: "#18181b", text: "#f4f4f5"}}
        slots={@slots}
      >
        <:header>
          <p>Ada Lovelace</p>
        </:header>
      </PreviewParts.theme_preview>
      """)

    assert [card] = html |> Floki.parse_fragment!() |> Floki.find("[data-preview='paper']")
    assert [style] = Floki.attribute(card, "style")
    assert style =~ "border-color: #f4f4f51f;"
    assert [class] = Floki.attribute(card, "class")
    refute class =~ "border-tymeslot"
  end
end
