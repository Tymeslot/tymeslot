defmodule TymeslotWeb.Components.DashboardComponents do
  @moduledoc """
  Shared UI components for the dashboard interface.
  Provides reusable form inputs, cards, modals, and other UI elements.
  """

  use Phoenix.Component
  import Phoenix.HTML
  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Icons.IconComponents

  @doc """
  Renders a form input with consistent styling.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :value, :any, required: true
  attr :placeholder, :string, default: ""
  attr :help, :string, default: nil
  attr :rest, :global

  @spec form_input(map()) :: Phoenix.LiveView.Rendered.t()
  def form_input(assigns) do
    ~H"""
    <div>
      <label for={@id} class="block text-sm font-medium text-gray-700 mb-1">
        {@label}
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={@value}
        placeholder={@placeholder}
        class="w-full px-3 py-2 glass-input focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent"
        {@rest}
      />
      <%= if @help do %>
        <p class="mt-1 text-sm text-gray-600">{@help}</p>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a select dropdown with consistent styling.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :options, :list, required: true
  attr :help, :string, default: nil
  attr :rest, :global

  @spec form_select(map()) :: Phoenix.LiveView.Rendered.t()
  def form_select(assigns) do
    ~H"""
    <div>
      <label for={@id} class="block text-sm font-medium text-gray-700 mb-1">
        {@label}
      </label>
      <div class="relative">
        <select
          id={@id}
          name={@name}
          class="w-full px-3 py-2 glass-input focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent appearance-none"
          {@rest}
        >
          <%= for {label, value} <- @options do %>
            <option value={value} selected={value == @value}>
              {label}
            </option>
          <% end %>
        </select>
        <div class="absolute inset-y-0 right-0 flex items-center pr-3 pointer-events-none">
          <svg class="h-5 w-5 text-gray-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
          </svg>
        </div>
      </div>
      <%= if @help do %>
        <p class="mt-1 text-sm text-gray-600">{@help}</p>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders an integration card (used in calendar and video integrations).
  """
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :details, :list, default: []
  slot :action, required: true

  @spec integration_card(map()) :: Phoenix.LiveView.Rendered.t()
  def integration_card(assigns) do
    ~H"""
    <div class="bg-white/5 rounded-lg p-4 border border-purple-400/20">
      <div class="flex items-start justify-between">
        <div class="flex-1">
          <h3 class="font-medium text-gray-800">{@title}</h3>
          <p class="text-sm text-gray-600 mt-1">{@subtitle}</p>
          <%= if @details != [] do %>
            <div class="mt-2 space-y-1">
              <%= for detail <- @details do %>
                <p class="text-xs text-gray-500">{detail}</p>
              <% end %>
            </div>
          <% end %>
        </div>
        <div class="flex items-center space-x-2">
          {render_slot(@action)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders an empty state with icon and optional action.
  """
  attr :icon_path, :string, required: true
  attr :message, :string, required: true
  slot :action

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div class="text-center py-12">
      <svg
        class="w-16 h-16 mx-auto text-gray-400/50 mb-4"
        fill="none"
        stroke="currentColor"
        viewBox="0 0 24 24"
      >
        {raw(@icon_path)}
      </svg>
      <p class="text-gray-600">{@message}</p>
      <%= if assigns[:action] do %>
        <div class="mt-4">
          {render_slot(@action)}
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a confirmation modal using CoreComponents.modal.
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :on_cancel, JS, default: %JS{}
  attr :on_confirm, :string, required: true
  attr :confirm_text, :string, default: "Confirm"
  attr :confirm_variant, :atom, default: :danger

  @spec confirmation_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirmation_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
      <:header>
        {@title}
      </:header>

      <p>{@message}</p>

      <:footer>
        <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
          Cancel
        </CoreComponents.action_button>
        <CoreComponents.action_button variant={@confirm_variant} phx-click={@on_confirm}>
          {@confirm_text}
        </CoreComponents.action_button>
      </:footer>
    </CoreComponents.modal>
    """
  end

  @doc """
  Renders a button with consistent styling.
  """
  attr :type, :string, default: "button"
  attr :variant, :atom, default: :primary
  attr :rest, :global
  slot :inner_block, required: true

  @spec button(map()) :: Phoenix.LiveView.Rendered.t()
  def button(assigns) do
    assigns = assign(assigns, :class, button_classes(assigns.variant))

    ~H"""
    <button type={@type} class={@class} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Renders a stat card for dashboard overview.
  """
  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true
  attr :link, :string, required: true
  attr :description, :string, required: true

  @spec stat_card(map()) :: Phoenix.LiveView.Rendered.t()
  def stat_card(assigns) do
    ~H"""
    <.link patch={@link} class="block">
      <div class="card-glass card-compact hover:border-purple-400/50 transition-all hover:bg-white/15">
        <div class="flex items-center">
          <div class="flex-shrink-0">
            <div class="w-10 h-10 bg-purple-600/20 rounded-full flex items-center justify-center">
              <IconComponents.icon name={@icon} class="w-5 h-5 text-teal-600" />
            </div>
          </div>
          <div class="ml-4 flex-1">
            <div class="text-2xl font-bold text-gray-800">{@value}</div>
            <div class="text-sm text-gray-600">{@title}</div>
            <div class="text-xs text-gray-500">{@description}</div>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  @doc """
  Reusable section header with icon, title, optional count badge and optional saving indicator.
  """
  attr :icon, :atom, required: true
  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :saving, :boolean, default: false
  attr :title_class, :string, default: "text-3xl font-bold text-gray-800"
  attr :class, :string, default: "flex items-center mb-8"

  @spec section_header(map()) :: Phoenix.LiveView.Rendered.t()
  def section_header(assigns) do
    ~H"""
    <div class={@class}>
      <div class="text-gray-600 mr-3">
        <IconComponents.icon name={@icon} class="w-8 h-8" />
      </div>
      <h1 class={@title_class}>{@title}</h1>
      <%= if @count do %>
        <span class="ml-2 bg-blue-100 text-blue-800 text-xs font-medium px-2.5 py-0.5 rounded-full">
          {@count}
        </span>
      <% end %>
      <%= if @saving do %>
        <span class="ml-auto text-green-400 text-sm flex items-center">
          <svg class="animate-spin h-4 w-4 mr-2" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
            </circle>
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            >
            </path>
          </svg>
          Saving...
        </span>
      <% end %>
    </div>
    """
  end

  # Private helpers

  defp button_classes(:primary), do: "btn btn-primary"
  defp button_classes(:secondary), do: "btn btn-secondary"
  defp button_classes(:danger), do: "btn bg-red-600 text-white hover:bg-red-700"
  defp button_classes(:ghost), do: "btn btn-ghost text-gray-600 hover:text-gray-800"
end
