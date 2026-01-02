defmodule TymeslotWeb.Components.UI.Toggle do
  @moduledoc """
  Reusable toggle component for switching between two options.
  Provides a consistent toggle interface throughout the application.
  """
  use Phoenix.Component

  @doc """
  Renders a toggle component with two options.

  ## Examples

      <Toggle.toggle
        id="input-mode-toggle"
        active_option={@input_mode}
        phx_click="toggle_input_mode"
        phx_target={@myself}
        options={[
          %{value: :list, label: "List View", icon: "list"},
          %{value: :grid, label: "Grid View", icon: "grid"}
        ]}
      />

      <Toggle.toggle
        id="theme-toggle"
        active_option={@theme}
        phx_click="toggle_theme"
        options={[
          %{value: :light, label: "Light", icon: "sun"},
          %{value: :dark, label: "Dark", icon: "moon"}
        ]}
      />
  """

  attr :id, :string, required: true, doc: "Unique identifier for the toggle component"
  attr :active_option, :atom, required: true, doc: "Currently active option value"

  attr :options, :list,
    required: true,
    doc: "List of option maps with :value, :label, and optional :icon"

  attr :phx_click, :string, required: true, doc: "Phoenix event to handle toggle clicks"
  attr :phx_target, :any, default: nil, doc: "Phoenix target for the event"
  attr :label, :string, default: nil, doc: "Optional label text to display before toggle"

  attr :size, :atom,
    default: :medium,
    values: [:small, :medium, :large],
    doc: "Size of the toggle"

  attr :disabled, :boolean, default: false, doc: "Whether the toggle is disabled"
  attr :class, :string, default: "", doc: "Additional CSS classes"

  @spec toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def toggle(assigns) do
    ~H"""
    <div class={["flex items-center space-x-3", @class]}>
      <%= if @label do %>
        <span class={["text-sm font-medium text-gray-700", get_label_classes(@size)]}>{@label}</span>
      <% end %>
      <div class={[
        "flex bg-white/5 backdrop-blur-sm border border-purple-200/30 rounded-lg",
        get_container_classes(@size),
        if(@disabled, do: "opacity-50 cursor-not-allowed", else: "")
      ]}>
        <%= for option <- @options do %>
          <button
            id={"#{@id}-#{option.value}"}
            phx-click={@phx_click}
            phx-target={@phx_target}
            phx-value-option={option.value}
            disabled={@disabled}
            class={[
              "flex items-center space-x-2 rounded-md text-sm font-medium transition-all duration-200",
              get_button_classes(@size),
              get_button_state_classes(option.value == @active_option, @disabled)
            ]}
          >
            <%= if Map.get(option, :icon) do %>
              <.render_icon icon={option.icon} size={@size} />
            <% end %>
            <span>{option.label}</span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions for sizing and styling

  defp get_label_classes(:small), do: "text-xs"
  defp get_label_classes(:medium), do: "text-sm"
  defp get_label_classes(:large), do: "text-base"

  defp get_container_classes(:small), do: "p-0.5"
  defp get_container_classes(:medium), do: "p-1"
  defp get_container_classes(:large), do: "p-1.5"

  defp get_button_classes(:small), do: "px-2 py-1 text-xs"
  defp get_button_classes(:medium), do: "px-4 py-2 text-sm"
  defp get_button_classes(:large), do: "px-6 py-3 text-base"

  defp get_button_state_classes(true, _disabled), do: "btn-primary"
  defp get_button_state_classes(false, true), do: "btn-ghost text-gray-400 cursor-not-allowed"
  defp get_button_state_classes(false, false), do: "btn-ghost text-gray-600 hover:text-gray-800"

  # Icon rendering function
  defp render_icon(assigns) do
    icon_class =
      case assigns.size do
        :small -> "w-3 h-3"
        :medium -> "w-4 h-4"
        :large -> "w-5 h-5"
      end

    assigns = assign(assigns, :icon_class, icon_class)

    ~H"""
    <%= case @icon do %>
      <% "list" -> %>
        <svg class={@icon_class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M4 6h16M4 10h16M4 14h16M4 18h16"
          />
        </svg>
      <% "grid" -> %>
        <svg class={@icon_class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6zM14 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2V6zM4 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2v-2zM14 16a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2h-2a2 2 0 01-2-2v-2z"
          />
        </svg>
      <% "sun" -> %>
        <svg class={@icon_class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z"
          />
        </svg>
      <% "moon" -> %>
        <svg class={@icon_class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z"
          />
        </svg>
      <% "calendar" -> %>
        <svg class={@icon_class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
          />
        </svg>
      <% "video" -> %>
        <svg class={@icon_class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"
          />
        </svg>
      <% "check" -> %>
        <svg class={@icon_class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
        </svg>
      <% "x" -> %>
        <svg class={@icon_class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M6 18L18 6M6 6l12 12"
          />
        </svg>
      <% "users" -> %>
        <svg class={@icon_class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197m13.5-9a2.5 2.5 0 11-5 0 2.5 2.5 0 015 0z"
          />
        </svg>
      <% "settings" -> %>
        <svg class={@icon_class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
          />
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
          />
        </svg>
      <% _ -> %>
        <!-- Default icon or custom icon can be added here -->
        <div class={[@icon_class, "bg-gray-400 rounded"]}></div>
    <% end %>
    """
  end
end
