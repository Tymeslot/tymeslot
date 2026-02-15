defmodule TymeslotWeb.Themes.Rhythm.Shared.StatusBadge do
  @moduledoc """
  Shared status badge component for the Rhythm theme.
  Displays an animated badge with icon for success, info, danger, or warning states.
  """
  use Phoenix.Component

  @doc """
  Renders a status badge with animated icon.

  ## Attributes
  - variant: Badge variant - "success", "info", "danger", or "warning"
  - icon: Icon type - "check", "info", "x", "refresh", or custom SVG path
  - transparent: Whether to use transparent background
  """
  attr :variant, :string, default: "success", values: ~w(success info danger warning)
  attr :icon, :string, default: "check", values: ~w(check info x refresh)
  attr :transparent, :boolean, default: false

  @spec status_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badge(assigns) do
    ~H"""
    <div class={"success-badge #{if @transparent, do: "success-badge--transparent", else: ""}"}>
      <div class={"success-badge-inner success-badge-inner--#{@variant}"}>
        <svg class="success-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <%= case @icon do %>
            <% "check" -> %>
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="3"
                d="M5 13l4 4L19 7"
              />
            <% "x" -> %>
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            <% "info" -> %>
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            <% "refresh" -> %>
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
              />
            <% _ -> %>
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
              />
          <% end %>
        </svg>
      </div>
    </div>
    """
  end
end
