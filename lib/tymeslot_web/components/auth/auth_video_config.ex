defmodule TymeslotWeb.Components.Auth.AuthVideoConfig do
  @moduledoc """
  Video configuration for authentication and onboarding flows.

  Handles video background settings for login, registration, and onboarding pages.
  Separate from scheduling theme configurations.
  """

  @doc """
  Get video configuration for authentication flows.
  Returns a map with video sources and poster information.
  """
  @spec get_auth_video_config() :: %{
          required(:background_videos) => [map()],
          required(:poster) => String.t(),
          required(:fallback_gradient) => String.t(),
          required(:crossfade_enabled) => boolean(),
          required(:video_ids) => [String.t()]
        }
  def get_auth_video_config do
    %{
      background_videos: [
        %{
          src: "/videos/backgrounds/background-video-desktop.webm",
          type: "video/webm",
          media: "(min-width: 1024px)"
        },
        %{
          src: "/videos/backgrounds/background-video-mobile.mp4",
          type: "video/mp4",
          media: "(max-width: 768px)"
        },
        %{
          src: "/videos/background-video-low.mp4",
          type: "video/mp4",
          media: "(max-width: 480px)"
        },
        %{
          src: "/videos/background-video-original.mp4",
          type: "video/mp4",
          media: nil
        }
      ],
      poster: "/images/ui/posters/auth-background-poster.webp",
      fallback_gradient: "linear-gradient(135deg, #667eea 0%, #764ba2 100%)",
      # Auth flows support crossfading
      crossfade_enabled: true,
      video_ids: ["auth-background-video-1", "auth-background-video-2"]
    }
  end

  @doc """
  Get video sources for authentication flows.
  """
  @spec auth_video_sources() :: [map()]
  def auth_video_sources do
    Map.get(get_auth_video_config(), :background_videos, [])
  end

  @doc """
  Get poster image for authentication flows.
  """
  @spec auth_video_poster() :: String.t()
  def auth_video_poster do
    Map.get(get_auth_video_config(), :poster)
  end

  @doc """
  Get fallback gradient for authentication flows.
  """
  @spec auth_fallback_gradient() :: String.t()
  def auth_fallback_gradient do
    Map.get(
      get_auth_video_config(),
      :fallback_gradient,
      "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"
    )
  end

  @doc """
  Check if authentication flows support crossfading videos.
  """
  @spec auth_crossfade_enabled?() :: boolean()
  def auth_crossfade_enabled? do
    Map.get(get_auth_video_config(), :crossfade_enabled, false)
  end

  @doc """
  Get video element IDs for authentication flows.
  """
  @spec auth_video_ids() :: [String.t()]
  def auth_video_ids do
    Map.get(get_auth_video_config(), :video_ids, [])
  end
end
