defmodule TymeslotWeb.Themes.Shared.Assets do
  @moduledoc """
  Asset configuration system for scheduling page themes.

  Handles video backgrounds, posters, and gradients for user-facing scheduling themes.
  For authentication/onboarding assets, see TymeslotWeb.Components.Auth.AuthVideoConfig.
  """

  @doc """
  Get video configuration for a specific scheduling theme.
  Returns a map with video sources and poster information.
  """
  @spec get_video_config(atom()) :: map()
  def get_video_config(theme)

  def get_video_config(:rhythm) do
    %{
      background_videos: [
        %{
          src: "/videos/backgrounds/rhythm-background-desktop.webm",
          type: "video/webm",
          media: "(min-width: 1024px)"
        },
        %{
          src: "/videos/backgrounds/rhythm-background-mobile.mp4",
          type: "video/mp4",
          media: "(max-width: 768px)"
        },
        %{
          src: "/videos/backgrounds/rhythm-background-low.mp4",
          type: "video/mp4",
          media: "(max-width: 480px)"
        },
        %{
          src: "/videos/backgrounds/rhythm-background-original.mp4",
          type: "video/mp4",
          media: nil
        }
      ],
      poster: "/images/ui/posters/rhythm-background-poster.webp",
      fallback_gradient: "linear-gradient(135deg, #667eea 0%, #764ba2 100%)",
      # Rhythm theme specific: supports crossfading
      crossfade_enabled: true,
      video_ids: ["rhythm-background-video-1", "rhythm-background-video-2"]
    }
  end

  def get_video_config(:quill) do
    %{
      background_videos: [],
      poster: nil,
      fallback_gradient: "linear-gradient(135deg, #1a1b3a 0%, #2d1b69 100%)"
    }
  end

  def get_video_config(_theme) do
    %{
      background_videos: [],
      poster: nil,
      fallback_gradient: "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"
    }
  end

  @doc """
  Generate video source elements for a given theme.
  Returns a list of source tag attributes.
  """
  @spec video_sources(atom()) :: list(map())
  def video_sources(theme) do
    theme
    |> get_video_config()
    |> Map.get(:background_videos, [])
  end

  @doc """
  Get poster image for a theme.
  """
  @spec video_poster(atom()) :: String.t() | nil
  def video_poster(theme) do
    theme
    |> get_video_config()
    |> Map.get(:poster)
  end

  @doc """
  Get fallback gradient for a theme.
  """
  @spec fallback_gradient(atom()) :: String.t()
  def fallback_gradient(theme) do
    theme
    |> get_video_config()
    |> Map.get(:fallback_gradient, "linear-gradient(135deg, #667eea 0%, #764ba2 100%)")
  end

  @doc """
  Check if a theme supports crossfading videos.
  """
  @spec crossfade_enabled?(atom()) :: boolean()
  def crossfade_enabled?(theme) do
    theme
    |> get_video_config()
    |> Map.get(:crossfade_enabled, false)
  end

  @doc """
  Get video element IDs for crossfading themes.
  """
  @spec video_ids(atom()) :: list(String.t())
  def video_ids(theme) do
    theme
    |> get_video_config()
    |> Map.get(:video_ids, [])
  end
end
