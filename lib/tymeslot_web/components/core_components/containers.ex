defmodule TymeslotWeb.Components.CoreComponents.Containers do
  @moduledoc "Container and display components extracted from CoreComponents."
  use Phoenix.Component

  # ========== CARDS & CONTAINERS ==========

  @doc """
  Renders a glass-morphism card container.
  """
  @spec glass_morphism_card(map()) :: Phoenix.LiveView.Rendered.t()
  def glass_morphism_card(assigns) do
    ~H"""
    <div class="glass-morphism-card">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a generic detail card with consistent styling.
  """
  attr :title, :string, default: nil
  slot :inner_block, required: true
  @spec detail_card(map()) :: Phoenix.LiveView.Rendered.t()
  def detail_card(assigns) do
    ~H"""
    <div class="meeting-details-card">
      <%= if @title do %>
        <h3 class="text-lg font-semibold mb-4 text-purple-900">{@title}</h3>
      <% end %>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders an icon badge with gradient background.
  """
  attr :color_from, :string, default: "#10b981"
  attr :color_to, :string, default: "#059669"
  attr :size, :atom, default: :medium, values: [:small, :medium, :large]
  slot :inner_block, required: true
  @spec icon_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def icon_badge(assigns) do
    size_classes =
      case assigns.size do
        :small -> "h-12 w-12"
        :large -> "h-20 w-20"
        _ -> "h-16 w-16"
      end

    icon_size =
      case assigns.size do
        :small -> "h-6 w-6"
        :large -> "h-10 w-10"
        _ -> "h-8 w-8"
      end

    assigns = assigns |> assign(:size_classes, size_classes) |> assign(:icon_size, icon_size)

    ~H"""
    <div
      class={"mx-auto flex items-center justify-center #{@size_classes} rounded-full mb-4"}
      style={"background: linear-gradient(135deg, #{@color_from} 0%, #{@color_to} 100%);"}
    >
      <svg class={"#{@icon_size} text-white"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
        {render_slot(@inner_block)}
      </svg>
    </div>
    """
  end

  @doc """
  Renders a section header with consistent styling.
  """
  attr :level, :integer, default: 1
  attr :class, :string, default: ""
  slot :inner_block, required: true
  @spec section_header(map()) :: Phoenix.LiveView.Rendered.t()
  def section_header(assigns) do
    size_class =
      case assigns.level do
        1 -> "text-3xl"
        2 -> "text-2xl"
        3 -> "text-xl"
        _ -> "text-lg"
      end

    assigns = assign(assigns, :size_class, size_class)

    ~H"""
    <h1
      class={"#{@size_class} font-bold mb-2 #{@class}"}
      style="color: white; text-shadow: 0 2px 4px rgba(0,0,0,0.1);"
    >
      {render_slot(@inner_block)}
    </h1>
    """
  end

  @doc """
  Renders an info/alert box.
  """
  attr :color_rgb, :string, default: "59, 130, 246"
  attr :variant, :atom, default: :info, values: [:info, :success, :warning, :error]
  slot :inner_block, required: true
  @spec info_box(map()) :: Phoenix.LiveView.Rendered.t()
  def info_box(assigns) do
    color =
      case assigns.variant do
        :success -> "16, 185, 129"
        :warning -> "251, 191, 36"
        :error -> "239, 68, 68"
        _ -> assigns.color_rgb
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <div
      class="rounded-lg p-4 mb-8"
      style={"background: rgba(#{@color}, 0.15); border: 1px solid rgba(#{@color}, 0.3);"}
    >
      <p style="color: white;">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end
end
