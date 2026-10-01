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
    assert html =~ "background: #2563eb;"
  end
end
