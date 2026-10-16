defmodule TymeslotWeb.Themes.Shared.VideoSources do
  @moduledoc """
  Renders the `<source>` elements of a background video from its descriptor's
  resolved source list (`Options.Background.descriptor/1`), in order.
  """
  use Phoenix.Component

  attr :sources, :list, required: true

  @spec video_sources(map()) :: Phoenix.LiveView.Rendered.t()
  def video_sources(assigns) do
    ~H"""
    <source :for={source <- @sources} src={source.src} type={source.type} media={source.media} />
    """
  end
end
