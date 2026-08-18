defmodule TymeslotWeb.Themes.Shared.Customization.Video do
  @moduledoc """
  Helper functions for rendering theme-specific video elements.
  Provides a unified interface while supporting theme-specific features like crossfading.
  """

  use Phoenix.Component

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.ThemeCustomizations.Validation

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

  @doc """
  Render responsive video sources for a user-uploaded video.
  Derives variant paths from the original upload path using the standard
  naming convention. The original file is always the last fallback source.

  Unlike preset sources (which use -original.mp4), upload sources use the
  original upload path verbatim as the fallback.
  """
  @spec render_upload_video_sources(String.t()) :: String.t()
  def render_upload_video_sources(upload_path) when is_binary(upload_path) do
    sanitized = Validation.sanitize_path(upload_path)
    base = Path.rootname(sanitized)

    variant_sources =
      Enum.map(Transcoder.variant_definitions(), fn variant ->
        %{src: "/uploads/#{base <> variant.suffix}", type: variant.type, media: variant.media}
      end)

    # Original upload is always the last fallback source
    fallback = %{src: "/uploads/#{sanitized}", type: "video/mp4", media: nil}

    render_video_sources(variant_sources ++ [fallback])
  end
end
