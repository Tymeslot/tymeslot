defmodule TymeslotWeb.Live.Scheduling.ThemeUtils do
  @moduledoc """
  Shared utilities for theme-specific LiveViews.

  This module provides common functionality that can be used across different
  themes while maintaining their independence.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [get_connect_params: 1]

  alias Tymeslot.Profiles
  alias Tymeslot.Scheduling.ThemeFlow
  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Themes.Core.Registry
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @doc """
  Assigns theme-related data including preview mode detection.

  `?theme=` selects which theme renders, and nothing else. A page is a preview
  only when the URL carries `?preview=` (`PreviewMode.claimed?/1`), which sets
  `:theme_preview`.

  `:theme_preview` is a claim, not an authorisation, and it is load-bearing in
  two different ways. It tunes rendering (the `iframe_embed.js` standalone
  bail-out), and it makes `BookingSubmissionHandlerComponent` fail a booking
  closed when no valid owner token backs the claim, so that a preview whose
  token expired mid-session cannot silently persist a real meeting the owner
  never sees. Whether a booking is simulated rather than blocked hangs off the
  verified, owner-bound `:owner_preview` token instead (see
  `LiveHelpers.assign_owner_preview/2`).

  Because the claim can block a booking, it must never be inferrable from a
  parameter a visitor can pick up by accident. That is why `?theme=` no longer
  counts: see `PreviewMode`.
  """
  @spec assign_theme_with_preview(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_theme_with_preview(socket, params) do
    theme_id = params["theme"] || socket.assigns[:theme_id] || Registry.default_theme_id()

    socket
    |> assign(:scheduling_theme_id, theme_id)
    |> assign(:scheduling_theme_css, ThemeInfo.get_css_file(theme_id))
    |> assign(:theme_preview, PreviewMode.claimed?(params))
  end

  @doc """
  Assigns `:attendee_prefill`, the name and email a booking link carried in
  its URL fragment, which the booking form starts from.

  The browser reads the fragment on page load and sends it with the LiveView
  connection (`attendee_prefill` in the connect params), so it never appears in
  a request URL. The static render has no connect params and assigns an empty
  map. Reads connect params, so it runs only during `mount/3`.
  """
  @spec assign_attendee_prefill(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_attendee_prefill(socket) do
    prefill = ThemeFlow.attendee_prefill((get_connect_params(socket) || %{})["attendee_prefill"])
    assign(socket, :attendee_prefill, prefill)
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
