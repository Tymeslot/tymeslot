defmodule TymeslotWeb.Themes.Shared.Customization.Video do
  @moduledoc """
  Helper functions for rendering theme-specific video elements.
  Provides a unified interface while supporting theme-specific features like crossfading.
  """

  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.Assets

  @doc """
  Render video container for a given theme.
  Handles both simple single videos and complex crossfading setups.
  """
  @spec render_video_container(atom(), map()) :: Phoenix.LiveView.Rendered.t()
  def render_video_container(theme, assigns \\ %{}) do
    if Assets.crossfade_enabled?(theme) do
      render_crossfade_videos(theme, assigns)
    else
      render_single_video(theme, assigns)
    end
  end

  defp render_single_video(theme, _assigns) do
    video_config = Assets.get_video_config(theme)
    video_id = "#{theme}-background-video"

    fallback_style =
      "background: #{video_config.fallback_gradient}; position: absolute; top: 0; left: 0; width: 100%; height: 100%;"

    assigns = %{
      video_config: video_config,
      video_id: video_id,
      fallback_style: fallback_style
    }

    ~H"""
    <video
      autoplay
      muted
      loop
      playsinline
      preload="metadata"
      poster={@video_config.poster}
      id={@video_id}
      class="video-background-video"
    >
      {Phoenix.HTML.raw(render_video_sources(@video_config.background_videos))}
      <!-- Fallback gradient background -->
      <div style={@fallback_style}></div>
    </video>
    """
  end

  defp render_crossfade_videos(theme, _assigns) do
    video_config = Assets.get_video_config(theme)
    [video_id_1, video_id_2] = video_config.video_ids

    fallback_style =
      "background: #{video_config.fallback_gradient}; position: absolute; top: 0; left: 0; width: 100%; height: 100%;"

    assigns = %{
      video_config: video_config,
      video_id_1: video_id_1,
      video_id_2: video_id_2,
      fallback_style: fallback_style
    }

    ~H"""
    <!-- Primary video element -->
    <video
      autoplay
      muted
      playsinline
      class="video-background-video active"
      id={@video_id_1}
      preload="metadata"
    >
      {Phoenix.HTML.raw(render_video_sources(@video_config.background_videos))}
      <!-- Fallback for missing video -->
      <div style={@fallback_style}></div>
    </video>

    <!-- Secondary video element for crossfading -->
    <video
      muted
      playsinline
      class="video-background-video inactive"
      id={@video_id_2}
      preload="metadata"
    >
      {Phoenix.HTML.raw(render_video_sources(@video_config.background_videos))}
      <!-- Fallback for missing video -->
      <div style={@fallback_style}></div>
    </video>
    """
  end

  defp render_video_sources(sources) do
    Enum.map_join(sources, "\n      ", fn video ->
      media_attr = if video.media, do: "media=\"#{video.media}\"", else: ""
      "<source src=\"#{video.src}\" type=\"#{video.type}\" #{media_attr} />"
    end)
  end

  @doc """
  Generate responsive video sources from a base video filename.
  Automatically creates desktop, mobile, low, and original quality variants.

  Examples:
    generate_responsive_video_sources("blue-wave-desktop.mp4")
    # Returns list of video source configs for all quality levels
  """
  @spec generate_responsive_video_sources(String.t()) :: list(map())
  def generate_responsive_video_sources(desktop_filename) when is_binary(desktop_filename) do
    base_name =
      desktop_filename
      |> String.replace("-desktop.mp4", "")
      |> String.replace("-desktop.webm", "")

    # Create responsive video sources in order of preference
    # Browser will use the first compatible format it supports
    responsive_sources = [
      # WebM for desktop (if available) - better compression
      %{
        src: "/videos/backgrounds/#{base_name}-desktop.webm",
        type: "video/webm",
        media: "(min-width: 1024px)"
      },
      # MP4 for desktop - wider compatibility
      %{
        src: "/videos/backgrounds/#{base_name}-desktop.mp4",
        type: "video/mp4",
        media: "(min-width: 1024px)"
      },
      # Mobile optimized
      %{
        src: "/videos/backgrounds/#{base_name}-mobile.mp4",
        type: "video/mp4",
        media: "(max-width: 768px)"
      },
      # Low bandwidth for small screens
      %{
        src: "/videos/backgrounds/#{base_name}-low.mp4",
        type: "video/mp4",
        media: "(max-width: 480px)"
      },
      # Fallback original quality
      %{
        src: "/videos/backgrounds/#{base_name}-original.mp4",
        type: "video/mp4",
        media: nil
      }
    ]

    # Filter out sources that don't exist (optional: could check file existence)
    # For now, we'll include all sources and let the browser handle 404s gracefully
    responsive_sources
  end

  @doc """
  Render responsive video sources from a preset filename.
  This is a convenience function that combines generation and rendering.
  """
  @spec render_preset_video_sources(String.t()) :: String.t()
  def render_preset_video_sources(desktop_filename) when is_binary(desktop_filename) do
    desktop_filename
    |> generate_responsive_video_sources()
    |> render_video_sources()
  end
end
