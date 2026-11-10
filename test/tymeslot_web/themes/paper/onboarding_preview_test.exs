defmodule TymeslotWeb.Themes.Paper.OnboardingPreviewTest do
  @moduledoc """
  Paper as the onboarding wizard draws it: its own thumbnail and card, not
  the generic mock, tinted with the organiser's accent, in the two panes of
  its first screen: the introduction on the left, a rule, and the chosen
  day marked, its times and Book on the right.
  """
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]

  alias Tymeslot.Availability.WeekPreview
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Paper.Theme

  @week %{
    state: :ready,
    preview: %WeekPreview{
      days: [%{date: ~D[2026-11-03], slots: ["09:00", "09:30"], busy: []}],
      slot_count: 2,
      first_busy: nil
    }
  }

  test "the thumbnail is Paper's own, tinted with the primary colour" do
    html =
      render_component(&PreviewParts.theme_preview/1,
        theme_module: Theme,
        variant: :thumbnail,
        primary: "#2563eb"
      )

    doc = Floki.parse_fragment!(html)

    assert [_tile] = Floki.find(doc, "[data-preview='paper']")
    assert [chosen, _other, _third] = Floki.find(doc, "[data-preview-part='type']")
    assert [style] = Floki.attribute(chosen, "style")
    assert style =~ "border-left: 2px solid #2563eb;"
  end

  test "the card sets the shared header beside the chosen day, its times and Book" do
    assigns = %{week: @week}

    html =
      rendered_to_string(~H"""
      <PreviewParts.theme_preview
        theme_module={Theme}
        variant={:card}
        colors={%{primary: "#2563eb", surface: "#ffffff", text: "#111111"}}
        week={@week}
        today={~D[2026-11-03]}
      >
        <:header>
          <p id="shared-header">Ada Lovelace</p>
        </:header>
      </PreviewParts.theme_preview>
      """)

    doc = Floki.parse_fragment!(html)

    assert [_card] = Floki.find(doc, "[data-preview='paper']")
    assert [intro] = Floki.find(doc, "[data-preview='paper'] > [data-preview-part='intro']")
    assert [_header] = Floki.find(intro, "#shared-header")
    assert [class] = Floki.attribute(intro, "class")
    assert class =~ "border-r"
    assert class =~ "items-start"

    assert [types] = Floki.find(doc, "[data-preview='paper'] > [data-preview-part='types']")
    assert [chosen] = Floki.find(types, "[data-preview-part='day']")
    assert Floki.text(chosen) =~ "Tuesday, 3 November"
    assert Floki.text(chosen) =~ "2 free times"
    assert [chosen_style] = Floki.attribute(chosen, "style")
    assert chosen_style =~ "border-left: 2px solid #2563eb;"
    assert [times] = Floki.find(types, "[data-preview-part='times']")
    assert Floki.text(times) =~ "09:30 AM"
    assert Floki.find(doc, "[data-preview-part='calendar']") == []
    assert [book] = Floki.find(types, "button")
    assert Floki.text(book) =~ "Book"
    assert [style] = Floki.attribute(book, "style")
    assert style =~ "background: #2563eb;"
  end

  test "the card's edge follows the text colour, so a dark card gets a light edge" do
    assigns = %{week: @week}

    html =
      rendered_to_string(~H"""
      <PreviewParts.theme_preview
        theme_module={Theme}
        variant={:card}
        colors={%{primary: "#0891b2", surface: "#18181b", text: "#f4f4f5"}}
        week={@week}
        today={~D[2026-11-03]}
      >
        <:header>
          <p>Ada Lovelace</p>
        </:header>
      </PreviewParts.theme_preview>
      """)

    assert [card] = html |> Floki.parse_fragment!() |> Floki.find("[data-preview='paper']")
    assert [style] = Floki.attribute(card, "style")
    assert style =~ "border-color: color-mix(in srgb, #f4f4f5 12%, transparent);"
    assert [class] = Floki.attribute(card, "class")
    refute class =~ "border-tymeslot"
  end
end
