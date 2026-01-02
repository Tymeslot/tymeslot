defmodule TymeslotWeb.Components.UI.ToggleGroup do
  @moduledoc """
  Button-style toggle group component for switching between multiple options.

  Perfect for view mode switching (List/Grid), filter options, or other 
  multi-option selections with glassmorphism styling.
  """
  use Phoenix.Component

  alias Phoenix.HTML

  attr :id, :string, required: true, doc: "Unique identifier for the toggle group"
  attr :active_option, :any, required: true, doc: "Currently active option value"

  attr :options, :list,
    required: true,
    doc: "List of options with :value, :label, :icon, and optional :short_label"

  attr :size, :atom, default: :medium, values: [:small, :medium, :large], doc: "Size variant"
  attr :on_change, :string, required: true, doc: "Phoenix event name to trigger on change"
  attr :target, :any, default: nil, doc: "Phoenix LiveView target"
  attr :label, :string, default: nil, doc: "Optional label for the toggle group"
  attr :class, :string, default: "", doc: "Additional CSS classes"

  @spec toggle_group(map()) :: Phoenix.LiveView.Rendered.t()
  def toggle_group(assigns) do
    ~H"""
    <div class={["flex items-center", spacing_class(@size), @class]}>
      <%= if @label do %>
        <span class={[
          "font-medium text-gray-700",
          label_class(@size)
        ]}>
          {@label}:
        </span>
      <% end %>

      <div class={[
        "flex bg-white/5 backdrop-blur-sm border border-purple-200/30 rounded-lg p-1",
        container_class(@size)
      ]}>
        <%= for option <- @options do %>
          <button
            phx-click={@on_change}
            phx-value-option={option.value}
            phx-target={@target}
            class={[
              "flex items-center transition-all duration-200",
              button_size_class(@size),
              button_state_class(@active_option == option.value)
            ]}
          >
            <%= if option[:icon] do %>
              <div class={icon_size_class(@size)}>
                {HTML.raw(option.icon)}
              </div>
            <% end %>
            
    <!-- Responsive text display -->
            <%= if option[:short_label] do %>
              <span class={responsive_text_class(@size, :full)}>
                {option.label}
              </span>
              <span class={responsive_text_class(@size, :short)}>
                {option.short_label}
              </span>
            <% else %>
              <span class={text_class(@size)}>
                {option.label}
              </span>
            <% end %>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # Size-based styling functions
  defp spacing_class(:small), do: "space-x-2"
  defp spacing_class(:medium), do: "space-x-2 sm:space-x-3"
  defp spacing_class(:large), do: "space-x-3"

  defp label_class(:small), do: "text-xs hidden sm:inline"
  defp label_class(:medium), do: "text-sm hidden sm:inline"
  defp label_class(:large), do: "text-base"

  defp container_class(:small), do: "text-xs"
  defp container_class(:medium), do: "text-sm"
  defp container_class(:large), do: "text-base"

  defp button_size_class(:small), do: "space-x-1 px-2 py-1.5 rounded text-xs font-medium"

  defp button_size_class(:medium),
    do: "space-x-1 sm:space-x-2 px-3 sm:px-4 py-2 rounded-md text-sm font-medium"

  defp button_size_class(:large), do: "space-x-2 px-4 py-3 rounded-lg text-base font-semibold"

  defp icon_size_class(:small), do: "w-3 h-3"
  defp icon_size_class(:medium), do: "w-4 h-4"
  defp icon_size_class(:large), do: "w-5 h-5"

  defp responsive_text_class(:small, :full), do: "hidden sm:inline text-xs"
  defp responsive_text_class(:small, :short), do: "sm:hidden text-xs"
  defp responsive_text_class(:medium, :full), do: "hidden sm:inline text-sm"
  defp responsive_text_class(:medium, :short), do: "sm:hidden text-sm"
  defp responsive_text_class(:large, :full), do: "text-base"
  defp responsive_text_class(:large, :short), do: "hidden"

  defp text_class(:small), do: "text-xs"
  defp text_class(:medium), do: "text-sm"
  defp text_class(:large), do: "text-base"

  defp button_state_class(true), do: "btn-primary"
  defp button_state_class(false), do: "btn-ghost text-gray-600 hover:text-gray-800"
end
