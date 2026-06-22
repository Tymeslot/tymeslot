defmodule TymeslotWeb.Components.CoreComponents.Navigation do
  @moduledoc "Navigation components extracted from CoreComponents."
  use Phoenix.Component

  # ========== NAVIGATION ==========

  @doc """
  Renders a detail row for definition lists.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true

  @spec detail_row(map()) :: Phoenix.LiveView.Rendered.t()
  def detail_row(assigns) do
    ~H"""
    <div class="flex justify-between">
      <dt style="color: rgba(255,255,255,0.7);">{@label}:</dt>
      <dd class="font-medium" style="color: white;">{@value}</dd>
    </div>
    """
  end

  @doc """
  Renders a styled back link.
  """
  attr :to, :string, required: true
  slot :inner_block, required: true

  @spec back_link(map()) :: Phoenix.LiveView.Rendered.t()
  def back_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class="text-sm underline text-white/70 hover:text-white/90 transition duration-200"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Renders a tabbed navigation interface.

  ## Usage

      <.tabs active_tab={@active_tab} target={@myself}>
        <:tab id="overview" label="Overview" icon={:home}>
          <p>Overview content here</p>
        </:tab>
        <:tab id="settings" label="Settings" icon={:cog}>
          <p>Settings content here</p>
        </:tab>
      </.tabs>

  ## Attributes

    * `active_tab` - The ID of the currently active tab (required)
    * `target` - The LiveComponent target for phx-target (optional, for LiveComponents)
  """
  attr :active_tab, :string, required: true
  attr :target, :any, default: nil

  slot :tab, required: true do
    attr :id, :string, required: true
    attr :label, :string, required: true
    attr :icon, :atom
  end

  @spec tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def tabs(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Tab Navigation --%>
      <div class="bg-white rounded-token-2xl border-2 border-tymeslot-100 p-2 shadow-sm">
        <nav
          role="tablist"
          aria-label="Tabs"
          class="flex flex-wrap gap-2"
        >
          <%= for tab <- @tab do %>
            <button
              type="button"
              role="tab"
              id={"tab-#{tab.id}"}
              aria-selected={to_string(@active_tab == tab.id)}
              aria-controls={"panel-#{tab.id}"}
              phx-click="switch_tab"
              phx-value-tab={tab.id}
              phx-target={@target}
              class={[
                "flex items-center gap-2 px-6 py-3 rounded-token-xl font-bold text-token-sm transition-all duration-300",
                if(@active_tab == tab.id,
                  do:
                    "bg-linear-to-r from-turquoise-600 to-cyan-600 text-white shadow-lg shadow-turquoise-500/30 transform scale-105",
                  else:
                    "text-tymeslot-600 hover:bg-tymeslot-50 hover:text-turquoise-700"
                )
              ]}
            >
              <%= if Map.get(tab, :icon) do %>
                <TymeslotWeb.Components.Icons.IconComponents.icon
                  name={tab.icon}
                  class="w-5 h-5"
                />
              <% end %>
              <span>{tab.label}</span>
            </button>
          <% end %>
        </nav>
      </div>

      <%!-- Tab Panels --%>
      <%= for tab <- @tab do %>
        <div
          role="tabpanel"
          id={"panel-#{tab.id}"}
          aria-labelledby={"tab-#{tab.id}"}
          hidden={@active_tab != tab.id}
          class={[
            "animate-in fade-in slide-in-from-bottom-4 duration-500",
            if(@active_tab != tab.id, do: "hidden")
          ]}
        >
          {render_slot(tab)}
        </div>
      <% end %>
    </div>
    """
  end
end
