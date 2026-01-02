defmodule TymeslotWeb.Components.UI.StatusSwitch do
  @moduledoc """
  Status switch component for on/off toggles with glassmorphism styling.

  Perfect for enabling/disabling integrations, features, or any binary state
  changes with animated slider and visual feedback.
  """
  use Phoenix.Component

  attr :id, :string, required: true, doc: "Unique identifier for the switch"
  attr :checked, :boolean, required: true, doc: "Current state of the switch"
  attr :size, :atom, default: :medium, values: [:small, :medium, :large], doc: "Size variant"
  attr :on_change, :string, required: true, doc: "Phoenix event name to trigger on change"
  attr :target, :any, default: nil, doc: "Phoenix LiveView target"
  attr :disabled, :boolean, default: false, doc: "Disabled state"
  attr :class, :string, default: "", doc: "Additional CSS classes"

  # Optional attributes for custom values
  attr :phx_value_id, :string, default: nil, doc: "Custom phx-value-id attribute"

  @spec status_switch(map()) :: Phoenix.LiveView.Rendered.t()
  def status_switch(assigns) do
    ~H"""
    <button
      phx-click={@on_change}
      phx-target={@target}
      phx-value-id={@phx_value_id}
      disabled={@disabled}
      class={[
        "status-toggle",
        size_class(@size),
        state_class(@checked),
        disabled_class(@disabled),
        @class
      ]}
      role="switch"
      aria-checked={@checked}
      id={@id}
    >
      <span class={[
        "status-toggle-slider",
        slider_state_class(@checked),
        slider_size_class(@size)
      ]}>
        <!-- Inactive icon (X) -->
        <span class={[
          "status-toggle-icon",
          icon_visibility_class(!@checked)
        ]}>
          <svg class={["status-icon", icon_size_class(@size)]} fill="none" viewBox="0 0 12 12">
            <path
              d="M4 8l2-2m0 0l2-2M6 6L4 4m2 2l2 2"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </span>
        
    <!-- Active icon (checkmark) -->
        <span class={[
          "status-toggle-icon",
          icon_visibility_class(@checked)
        ]}>
          <svg
            class={["status-icon status-icon--white", icon_size_class(@size)]}
            fill="currentColor"
            viewBox="0 0 12 12"
          >
            <path d="M3.707 5.293a1 1 0 00-1.414 1.414l1.414-1.414zM5 7l-.707.707a1 1 0 001.414 0L5 7zm4.707-3.293a1 1 0 00-1.414-1.414l1.414 1.414zm-7.414 2l2 2 1.414-1.414-2-2-1.414 1.414zm3.414 2l4-4-1.414-1.414-4 4 1.414 1.414z" />
          </svg>
        </span>
      </span>
    </button>
    """
  end

  # Size-based styling functions
  defp size_class(:small) do
    "h-5 w-9 border border-gray-300"
  end

  defp size_class(:medium) do
    "h-6 w-11 border-2"
  end

  defp size_class(:large) do
    "h-7 w-12 border-2"
  end

  defp slider_size_class(:small), do: "h-4 w-4"
  defp slider_size_class(:medium), do: "h-5 w-5"
  defp slider_size_class(:large), do: "h-6 w-6"

  defp icon_size_class(:small), do: "h-2.5 w-2.5"
  defp icon_size_class(:medium), do: "h-3 w-3"
  defp icon_size_class(:large), do: "h-3.5 w-3.5"

  # State-based styling functions
  defp state_class(true), do: "status-toggle--active"
  defp state_class(false), do: "status-toggle--inactive"

  defp slider_state_class(true), do: "status-toggle-slider--active"
  defp slider_state_class(false), do: ""

  defp icon_visibility_class(true), do: "status-toggle-icon--visible"
  defp icon_visibility_class(false), do: "status-toggle-icon--hidden"

  defp disabled_class(true), do: "opacity-50 cursor-not-allowed"
  defp disabled_class(false), do: "cursor-pointer"
end
