defmodule TymeslotWeb.Themes.Shared.VideoSourcesTest do
  @moduledoc """
  `<.video_sources>` renders a background video's resolved source list. The
  `media` query is what lets the browser pick the right size, so it must reach
  each `<source>` that has one and be absent from the fallback that has none.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias TymeslotWeb.Themes.Shared.VideoSources

  defp render_sources(sources) do
    assigns = %{sources: sources}
    rendered_to_string(~H"<VideoSources.video_sources sources={@sources} />")
  end

  test "a source with a media query carries it" do
    html =
      render_sources([
        %{src: "/videos/clip-desktop.webm", type: "video/webm", media: "(min-width: 1024px)"}
      ])

    assert html =~
             ~s|<source src="/videos/clip-desktop.webm" type="video/webm" media="(min-width: 1024px)">|
  end

  test "a source without a media query renders no media attribute" do
    html = render_sources([%{src: "/uploads/clip.mp4", type: "video/mp4", media: nil}])

    assert html =~ ~s(<source src="/uploads/clip.mp4" type="video/mp4">)
    refute html =~ "media="
  end
end
