defmodule TymeslotWeb.Live.Scheduling.ThemeUtils do
  @moduledoc """
  Shared utilities for theme-specific LiveViews.

  This module provides common functionality that can be used across different
  themes while maintaining their independence.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [get_connect_params: 1]

  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Core.Registry
  alias TymeslotWeb.Themes.Core.ThemeInfo

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
    theme_id = socket.assigns[:theme_id] || Registry.default_theme_id()

    socket
    |> assign(:scheduling_theme_id, theme_id)
    |> assign(:scheduling_theme_css, ThemeInfo.get_css_file(theme_id))
  end

  @doc """
  Assigns theme-related data including preview mode detection.

  A page is a preview when the URL carries either `?theme=` (a theme-switch
  preview, which also selects the previewed theme id) or `?preview=` (the
  owner previewing their own published page, keeping the stored theme). Both
  set `:theme_preview`, a **display-only** signal (it tunes rendering, e.g. the
  `iframe_embed.js` standalone bail-out).

  It deliberately does NOT gate booking persistence: the booking page is
  public, so simulate-vs-persist hangs off the verified, owner-bound
  `:owner_preview` token instead (see `LiveHelpers.assign_owner_preview/2`).
  """
  @spec assign_theme_with_preview(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_theme_with_preview(socket, params) do
    theme_switch = Map.has_key?(params, "theme")
    theme_preview = theme_switch or Map.has_key?(params, "preview")

    # Only a theme-switch preview picks the theme id from the URL; an owner
    # preview keeps whatever theme is already assigned.
    theme_id =
      if theme_switch do
        params["theme"] || socket.assigns[:theme_id] || Registry.default_theme_id()
      else
        socket.assigns[:theme_id] || Registry.default_theme_id()
      end

    socket
    |> assign(:scheduling_theme_id, theme_id)
    |> assign(:scheduling_theme_css, ThemeInfo.get_css_file(theme_id))
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
    normalized_timezone = Timezones.normalize(timezone)

    # Validate timezone and fallback if invalid
    validated_timezone =
      if Timezones.valid?(normalized_timezone) do
        normalized_timezone
      else
        # Fallback to profile default or UTC if even that is broken
        default_tz = Profiles.get_default_timezone()

        if Timezones.valid?(default_tz) do
          default_tz
        else
          "UTC"
        end
      end

    assign(socket, :user_timezone, validated_timezone)
  end
end
