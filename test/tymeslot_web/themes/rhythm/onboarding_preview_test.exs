defmodule TymeslotWeb.Themes.Rhythm.OnboardingPreviewTest do
  @moduledoc """
  Rhythm as the onboarding wizard draws it: atmosphere first, as on the real
  page. The host's background runs behind a glass card, as a still (a
  video's poster, never the video), with the pause control a moving
  background carries; without a picture the palette's canvas glows with the
  primary colour.
  """
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]

  alias Tymeslot.Availability.WeekPreview
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Rhythm.Theme

  @week %{
    state: :ready,
    preview: %WeekPreview{
      days: [%{date: ~D[2026-11-03], slots: ["09:00", "09:30"], busy: []}],
      slot_count: 2,
      first_busy: nil
    }
  }

  @video %{
    kind: :video,
    sources: [%{src: "/videos/backgrounds/space-desktop.mp4", type: "video/mp4", media: nil}],
    poster: "/images/ui/posters/space-poster.jpg"
  }

  defp card(background) do
    assigns = %{week: @week, background: background}

    html =
      rendered_to_string(~H"""
      <PreviewParts.theme_preview
        theme_module={Theme}
        variant={:card}
        colors={%{primary: "#06b6d4", background: "#0f172a", surface: "#1e293b"}}
        background={@background}
        week={@week}
        today={~D[2026-11-03]}
      >
        <:header>
          <p id="shared-header">Ada Lovelace</p>
        </:header>
      </PreviewParts.theme_preview>
      """)

    Floki.parse_fragment!(html)
  end

  defp backdrop_style(doc) do
    [style] =
      doc
      |> Floki.find("[data-preview='rhythm'] > [data-preview-part='backdrop']")
      |> Floki.attribute("style")

    style
  end

  test "the thumbnail is Rhythm's own: a glass card over its default background" do
    html =
      render_component(&PreviewParts.theme_preview/1,
        theme_module: Theme,
        variant: :thumbnail,
        primary: "#06b6d4"
      )

    assert [tile] = html |> Floki.parse_fragment!() |> Floki.find("[data-preview='rhythm']")
    assert [style] = Floki.attribute(tile, "style")
    assert style =~ "/images/ui/posters/rhythm-background-poster.jpg"
  end

  test "a video background shows as its poster behind the card, never as a video" do
    doc = card(@video)

    assert backdrop_style(doc) =~ "url('/images/ui/posters/space-poster.jpg')"
    assert Floki.find(doc, "video") == []
    assert [_toggle] = Floki.find(doc, "[data-preview-part='motion-toggle']")
    assert [_header] = Floki.find(doc, "[data-preview='rhythm'] #shared-header")
    assert [_strip] = Floki.find(doc, "[data-preview-part='days']")
    assert Floki.find(doc, "[data-preview-part='month']") == []
  end

  test "an image background shows as itself, with no pause control" do
    doc = card(%{kind: :image, url: "/uploads/themes/1/2/images/mine.jpg"})

    assert backdrop_style(doc) =~ "url('/uploads/themes/1/2/images/mine.jpg')"
    assert Floki.find(doc, "[data-preview-part='motion-toggle']") == []
  end

  test "with no picture the canvas glows with the primary colour" do
    for background <- [nil, %{kind: :color, color: "#112233"}] do
      style = background |> card() |> backdrop_style()

      refute style =~ "url("
      assert style =~ "radial-gradient"
      assert style =~ "#06b6d4"
      assert style =~ "#0f172a"
    end
  end
end
