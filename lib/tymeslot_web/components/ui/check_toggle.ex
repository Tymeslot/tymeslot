defmodule TymeslotWeb.Components.UI.CheckToggle do
  @moduledoc """
  A standalone, event-driven checkbox for marking an item done — a rounded tick
  that fills on completion.

  Unlike the form `<.input type="checkbox">`, this is not bound to a changeset:
  it dispatches a Phoenix event on click, so it suits action toggles such as
  checklist items or "mark as done" affordances. Styling follows the app's
  checkbox language — a `tymeslot-300` border when empty, a turquoise hover cue,
  and a success-green fill with a check when set.
  """
  use Phoenix.Component

  alias TymeslotWeb.Components.Icons.IconComponents

  attr :id, :string, required: true, doc: "Unique identifier for the control"
  attr :checked, :boolean, required: true, doc: "Whether the item is done"
  attr :on_change, :string, required: true, doc: "Phoenix event to dispatch on click"
  attr :target, :any, default: nil, doc: "Phoenix LiveView/LiveComponent target"
  attr :phx_value_id, :string, default: nil, doc: "Value sent as phx-value-id"
  attr :label, :string, default: nil, doc: "Accessible label describing the item"
  attr :size, :atom, default: :medium, values: [:small, :medium, :large], doc: "Size variant"
  attr :disabled, :boolean, default: false, doc: "Disabled state"
  attr :class, :string, default: "", doc: "Additional CSS classes"

  @spec check_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def check_toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@on_change}
      phx-target={@target}
      phx-value-id={@phx_value_id}
      disabled={@disabled}
      role="checkbox"
      aria-checked={to_string(@checked)}
      aria-label={@label}
      class={[
        "shrink-0 flex items-center justify-center rounded-token-md border-2 transition-colors",
        size_class(@size),
        state_class(@checked),
        disabled_class(@disabled),
        @class
      ]}
      id={@id}
    >
      <IconComponents.icon name={:check} class={icon_size_class(@size)} />
    </button>
    """
  end

  defp size_class(:small), do: "w-5 h-5"
  defp size_class(:medium), do: "w-6 h-6"
  defp size_class(:large), do: "w-7 h-7"

  defp icon_size_class(:small), do: "w-3 h-3"
  defp icon_size_class(:medium), do: "w-4 h-4"
  defp icon_size_class(:large), do: "w-5 h-5"

  defp state_class(true), do: "bg-emerald-500 border-emerald-500 text-white"

  defp state_class(false),
    do: "bg-white border-tymeslot-300 text-transparent hover:border-turquoise-400"

  defp disabled_class(true), do: "opacity-50 cursor-not-allowed"
  defp disabled_class(false), do: "cursor-pointer"
end
