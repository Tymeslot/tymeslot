defmodule TymeslotWeb.Components.CoreComponents.Containers do
  @moduledoc "Container and display components extracted from CoreComponents."
  use Phoenix.Component

  # ========== CARDS & CONTAINERS ==========

  @doc """
  Renders a brand-styled card container.
  """
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec brand_card(Phoenix.LiveView.Assigns.t()) :: Phoenix.LiveView.Rendered.t()
  def brand_card(assigns) do
    ~H"""
    <div class={["brand-card", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a glass-morphism card container.
  """
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec glass_morphism_card(Phoenix.LiveView.Assigns.t()) :: Phoenix.LiveView.Rendered.t()
  def glass_morphism_card(assigns) do
    ~H"""
    <div class={["glass-morphism-card", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a generic detail card with consistent styling.
  """
  attr :title, :string, default: nil
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec detail_card(Phoenix.LiveView.Assigns.t()) :: Phoenix.LiveView.Rendered.t()
  def detail_card(assigns) do
    ~H"""
    <div class={["meeting-details-card", @class]}>
      <%= if @title do %>
        <h3 class="text-xl font-black mb-4 text-tymeslot-900 tracking-tight">{@title}</h3>
      <% end %>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders an icon badge with gradient background.
  """
  attr :size, :atom, default: :medium, values: [:small, :medium, :large]
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec icon_badge(Phoenix.LiveView.Assigns.t()) :: Phoenix.LiveView.Rendered.t()
  def icon_badge(assigns) do
    size_classes =
      case assigns.size do
        :small -> "h-12 w-12"
        :large -> "h-24 w-24"
        _other -> "h-16 w-16"
      end

    icon_size =
      case assigns.size do
        :small -> "h-6 w-6"
        :large -> "h-12 w-12"
        _other -> "h-8 w-8"
      end

    assigns = assigns |> assign(:size_classes, size_classes) |> assign(:icon_size, icon_size)

    ~H"""
    <div
      class={["mx-auto flex items-center justify-center #{@size_classes} rounded-3xl mb-6 bg-gradient-to-br from-turquoise-600 to-cyan-600 shadow-xl shadow-turquoise-500/20 border-4 border-white transform transition-transform hover:scale-110", @class]}
    >
      <svg class={"#{@icon_size} text-white"} fill="none" stroke="currentColor" viewBox="0 0 24 24" stroke-width="2.5">
        {render_slot(@inner_block)}
      </svg>
    </div>
    """
  end

  @doc """
  Renders a section header with consistent styling. Supports optional icon, count badge, and saving indicator.
  """
  attr :icon, :atom, default: nil
  attr :title, :string, default: nil
  attr :count, :integer, default: nil
  attr :saving, :boolean, default: false
  attr :level, :integer, default: 1
  attr :title_class, :string, default: nil
  attr :class, :string, default: ""
  slot :inner_block

  @spec section_header(Phoenix.LiveView.Assigns.t()) :: Phoenix.LiveView.Rendered.t()
  def section_header(assigns) do
    size_class =
      case assigns.level do
        1 -> "text-4xl"
        2 -> "text-3xl"
        3 -> "text-2xl"
        _other -> "text-xl"
      end

    computed_title_class =
      assigns.title_class || "#{size_class} font-black text-tymeslot-900 tracking-tight"

    assigns =
      assigns
      |> assign(:size_class, size_class)
      |> assign(:computed_title_class, computed_title_class)

    ~H"""
    <div :if={@icon} class={["flex items-center mb-4", @class]}>
      <div class="w-14 h-14 bg-white rounded-2xl flex items-center justify-center mr-5 shadow-sm border border-tymeslot-100 flex-shrink-0">
        <TymeslotWeb.Components.Icons.IconComponents.icon name={@icon} class="w-8 h-8 text-turquoise-600" />
      </div>

      <h1 class={@computed_title_class}>
        <%= if @title do %>
          {@title}
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </h1>

      <%= if @count do %>
        <span class="ml-4 bg-turquoise-100 text-turquoise-700 text-xs font-black px-3 py-1 rounded-full uppercase tracking-wider">
          {@count}
        </span>
      <% end %>

      <%= if @saving do %>
        <div class="ml-auto bg-emerald-50 text-emerald-700 px-4 py-2 rounded-full font-black text-xs uppercase tracking-wider border-2 border-emerald-100 flex items-center">
          <svg class="animate-spin h-4 w-4 mr-2" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
          Saving changes...
        </div>
      <% end %>
    </div>

    <h1 :if={!@icon} class={[@computed_title_class, "mb-2", @class]}>
      <%= if @title do %>
        {@title}
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </h1>
    """
  end

  @doc """
  Renders an info/alert box.
  """
  attr :variant, :atom, default: :info, values: [:info, :success, :warning, :error]
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec info_box(Phoenix.LiveView.Assigns.t()) :: Phoenix.LiveView.Rendered.t()
  def info_box(assigns) do
    classes =
      case assigns.variant do
        :success -> "bg-emerald-50 border-emerald-200 text-emerald-800"
        :warning -> "bg-amber-50 border-amber-200 text-amber-800"
        :error -> "bg-red-50 border-red-200 text-red-800"
        :info -> "bg-sky-50 border-sky-200 text-sky-800"
        _other -> "bg-tymeslot-50 border-tymeslot-200 text-tymeslot-800"
      end

    assigns = assign(assigns, :classes, classes)

    ~H"""
    <div class={["rounded-2xl p-6 mb-8 border-2", @classes, @class]}>
      <p class="font-medium">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end
end
