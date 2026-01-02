defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents do
  @moduledoc """
  Shared UI components for integration configuration pages.
  Reduces code duplication across calendar and video integration configs.
  """
  use TymeslotWeb, :html

  @doc """
  Renders a close button (red X) in the top-right corner.

  ## Examples

      <.close_button target={@target} />
  """
  attr :target, :any, required: true
  attr :class, :string, default: "absolute top-0 right-0"

  @spec close_button(map()) :: Phoenix.LiveView.Rendered.t()
  def close_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="back_to_providers"
      phx-target={@target}
      class={[
        @class,
        "group flex items-center gap-1 p-2 text-red-500 hover:text-red-700",
        "hover:bg-red-50 rounded-md transition-all duration-200",
        "focus:outline-none focus:ring-2 focus:ring-red-500 focus:ring-offset-2"
      ]}
      title="Close"
    >
      <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M6 18L18 6M6 6l12 12"
        />
      </svg>
      <span class="text-sm font-medium text-red-500 group-hover:text-red-700 transition-colors duration-200">
        Close
      </span>
    </button>
    """
  end

  @doc """
  Renders a loading spinner animation.

  ## Examples

      <.loading_spinner />
  """
  attr :class, :string, default: "h-4 w-4"

  @spec loading_spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def loading_spinner(assigns) do
    ~H"""
    <svg class={["animate-spin", @class]} fill="none" viewBox="0 0 24 24">
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      />
    </svg>
    """
  end

  @doc """
  Renders a form submit button with loading state.

  ## Examples

      <.form_submit_button saving={@saving} />
      <.form_submit_button saving={@saving} text="Save Integration" />
  """
  attr :saving, :boolean, required: true
  attr :text, :string, default: "Add Integration"
  attr :saving_text, :string, default: "Adding..."
  attr :class, :string, default: "btn btn-primary"

  @spec form_submit_button(map()) :: Phoenix.LiveView.Rendered.t()
  def form_submit_button(assigns) do
    ~H"""
    <button type="submit" disabled={@saving} class={@class}>
      <%= if @saving do %>
        <span class="flex items-center">
          <.loading_spinner class="h-4 w-4 mr-2" />
          {@saving_text}
        </span>
      <% else %>
        {@text}
      <% end %>
    </button>
    """
  end

  @doc """
  Renders a secondary button for cancel/back actions.
  """
  attr :target, :any, required: true
  attr :label, :string, default: "Cancel"
  attr :icon, :string, default: nil
  attr :phx_click, :string, default: "back_to_providers"
  attr :class, :string, default: "btn btn-secondary"

  @spec secondary_button(map()) :: Phoenix.LiveView.Rendered.t()
  def secondary_button(assigns) do
    ~H"""
    <button
      type="button"
      class={@class}
      phx-click={@phx_click}
      phx-target={@target}
    >
      <%= if @icon do %>
        <.icon name={@icon} class="w-4 h-4 mr-2" />
      <% end %>
      {@label}
    </button>
    """
  end
end
