defmodule TymeslotWeb.Components.UI.StatusSwitch do
  @moduledoc """
  Status switch component for on/off toggles with glassmorphism styling.

  Perfect for enabling/disabling integrations, features, or any binary state
  changes with animated slider and visual feedback.
  """
  use Phoenix.Component

  alias TymeslotWeb.Components.CoreComponents.Icons

  attr :id, :string, required: true, doc: "Unique identifier for the switch"
  attr :checked, :boolean, required: true, doc: "Current state of the switch"
  attr :size, :atom, default: :medium, values: [:small, :medium, :large], doc: "Size variant"
  attr :on_change, :string, required: true, doc: "Phoenix event name to trigger on change"
  attr :target, :any, default: nil, doc: "Phoenix LiveView target"
  attr :disabled, :boolean, default: false, doc: "Disabled state"
  attr :class, :string, default: "", doc: "Additional CSS classes"

  attr :aria_label, :string,
    default: nil,
    doc: "Accessible label describing what the switch toggles"

  attr :rest, :global, doc: "Further attributes (`phx-value-*`, `aria-labelledby`, `data-testid`)"

  @spec status_switch(map()) :: Phoenix.LiveView.Rendered.t()
  def status_switch(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@on_change}
      phx-target={@target}
      disabled={@disabled}
      class={[
        "status-toggle",
        size_class(@size),
        state_class(@checked),
        disabled_class(@disabled),
        @class
      ]}
      role="switch"
      aria-checked={to_string(@checked)}
      aria-label={@aria_label}
      id={@id}
      {@rest}
    >
      <span class={[
        "status-toggle-slider",
        slider_state_class(@checked, @size),
        slider_size_class(@size)
      ]}>
        <%!-- Inactive icon (X) --%>
        <span class={[
          "status-toggle-icon",
          icon_visibility_class(!@checked)
        ]}>
          <Icons.icon name="hero-x-mark-micro" class={"status-icon " <> icon_size_class(@size)} />
        </span>

        <%!-- Active icon (checkmark) --%>
        <span class={[
          "status-toggle-icon",
          icon_visibility_class(@checked)
        ]}>
          <Icons.icon
            name="hero-check-micro"
            class={"status-icon status-icon--white " <> icon_size_class(@size)}
          />
        </span>
      </span>
    </button>
    """
  end

  # Size-based styling functions
  defp size_class(:small), do: "h-5 w-9 border"
  defp size_class(:medium), do: "h-6 w-11 border-2"
  defp size_class(:large), do: "h-7 w-12 border-2"

  defp slider_size_class(:small), do: "h-4 w-4"
  defp slider_size_class(:medium), do: "h-5 w-5"
  defp slider_size_class(:large), do: "h-6 w-6"

  defp icon_size_class(:small), do: "h-2.5 w-2.5"
  defp icon_size_class(:medium), do: "h-3 w-3"
  defp icon_size_class(:large), do: "h-3.5 w-3.5"

  # State-based styling functions
  defp state_class(true), do: "status-toggle--active"
  defp state_class(false), do: "status-toggle--inactive"

  # The slider travels the track's inner width less its own: 2.25rem - 2px -
  # 1rem on the small track, 2.75rem - 4px - 1.25rem on the medium and
  # 3rem - 4px - 1.5rem on the large.
  defp slider_state_class(true, :small), do: "status-toggle-slider--active translate-x-4.5"
  defp slider_state_class(true, _size), do: "status-toggle-slider--active translate-x-5"
  defp slider_state_class(false, _size), do: nil

  defp icon_visibility_class(true), do: "status-toggle-icon--visible"
  defp icon_visibility_class(false), do: "status-toggle-icon--hidden"

  defp disabled_class(true), do: "opacity-50 cursor-not-allowed"
  defp disabled_class(false), do: "cursor-pointer"
end
