defmodule TymeslotWeb.Live.Scheduling.ThemeUtils do
  @moduledoc """
  Shared utilities for theme-specific LiveViews.

  This module provides common functionality that can be used across different
  themes while maintaining their independence.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [get_connect_params: 1]

  alias Tymeslot.Scheduling.ThemeFlow
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Themes.Core.Registry

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
  `LiveHelpers.Mount`'s owner-preview gate).

  Because the claim can block a booking, it must never be inferrable from a
  parameter a visitor can pick up by accident. That is why `?theme=` no longer
  counts: see `PreviewMode`.
  """
  @spec assign_theme_with_preview(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_theme_with_preview(socket, params) do
    theme_id =
      Registry.requested_theme_id(params) || socket.assigns[:theme_id] ||
        Registry.default_theme_id()

    socket
    |> assign(:scheduling_theme_id, theme_id)
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
end
