defmodule TymeslotWeb.Components.UI.CloseButton do
  @moduledoc """
  Shared close button component for overlays and modals.
  Provides a consistent close button UI across the application.
  """
  use Phoenix.Component

  @doc """
  Renders a close button with optional label.

  ## Attributes
  - `phx_click` - The event to trigger when clicked (required)
  - `phx_target` - The target for the event (optional)
  - `title` - Tooltip text for the button (default: "Close")
  - `show_label` - Whether to show the "Close" label text (default: true)
  - `class` - Additional CSS classes to apply to the button
  """
  attr :phx_click, :string, required: true
  attr :phx_target, :any, default: nil
  attr :title, :string, default: "Close"
  attr :show_label, :boolean, default: true
  attr :class, :string, default: ""

  @spec close_button(map()) :: Phoenix.LiveView.Rendered.t()
  def close_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@phx_click}
      phx-target={@phx_target}
      class={[
        "group flex items-center gap-1 p-2 text-red-500 hover:text-red-700",
        "hover:bg-red-50 rounded-md transition-all duration-200",
        "focus:outline-none focus:ring-2 focus:ring-red-500 focus:ring-offset-2",
        @class
      ]}
      title={@title}
    >
      <svg class="w-5 h-5 sm:w-6 sm:h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M6 18L18 6M6 6l12 12"
        />
      </svg>
      <%= if @show_label do %>
        <span class="text-sm font-medium text-red-500 group-hover:text-red-700 transition-colors duration-200">
          Close
        </span>
      <% end %>
    </button>
    """
  end
end
