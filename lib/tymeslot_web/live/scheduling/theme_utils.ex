defmodule TymeslotWeb.Live.Scheduling.ThemeUtils do
  @moduledoc """
  Shared utilities for theme-specific LiveViews.

  This module provides common functionality that can be used across different
  themes while maintaining their independence.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [get_connect_params: 1]

  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Theme
  alias Tymeslot.Utils.TimezoneUtils

  @doc """
  Assigns theme-related data to the socket dynamically based on the theme_id.

  This replaces hardcoded theme assignments and allows themes to work
  correctly with debug routes and theme switching.

  ## Examples

      # In a theme LiveView:
      socket = assign_theme(socket)

      # In debug context:
      socket = assign(socket, :theme_id, "2")
      socket = assign_theme(socket)
  """
  @spec assign_theme(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_theme(socket) do
    theme_id = socket.assigns[:theme_id] || "1"

    socket
    |> assign(:scheduling_theme_id, theme_id)
    |> assign(:scheduling_theme_css, Theme.get_css_file(theme_id))
  end

  @doc """
  Assigns theme-related data including preview mode detection.

  This function checks for the "theme" parameter in params to enable
  preview mode, which preserves the theme parameter during navigation.
  """
  @spec assign_theme_with_preview(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_theme_with_preview(socket, params) do
    # Check if we're in preview mode (theme parameter present in URL)
    theme_preview = Map.has_key?(params, "theme")

    # Use theme from URL params if in preview mode, otherwise use default
    theme_id =
      if theme_preview do
        params["theme"] || socket.assigns[:theme_id] || "1"
      else
        socket.assigns[:theme_id] || "1"
      end

    socket
    |> assign(:scheduling_theme_id, theme_id)
    |> assign(:scheduling_theme_css, Theme.get_css_file(theme_id))
    |> assign(:theme_preview, theme_preview)
  end

  @doc """
  Assigns the user's timezone from browser detection or parameters.

  This function detects the user's timezone from:
  1. Browser-detected timezone (via JavaScript in connect_params)
  2. Explicit timezone parameter (from URL or form)
  3. System default timezone as fallback

  This is common logic used by most themes during initialization.
  """
  @spec assign_user_timezone(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_user_timezone(socket, params) do
    # Try to get timezone from browser detection, then params, then default
    timezone =
      get_connect_params(socket)["timezone"] ||
        params["timezone"] ||
        Profiles.get_default_timezone()

    # Normalize timezone to ensure consistency
    normalized_timezone = TimezoneUtils.normalize_timezone(timezone)
    assign(socket, :user_timezone, normalized_timezone)
  end
end
