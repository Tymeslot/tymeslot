defmodule TymeslotWeb.Components.CoreComponents.Navigation do
  @moduledoc "Navigation components extracted from CoreComponents."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

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
        <:tab id="overview" label="Overview" icon="hero-home">
          <p>Overview content here</p>
        </:tab>
        <:tab id="settings" label="Settings" icon="hero-cog-6-tooth">
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
    attr :icon, :string, doc: "Optional `hero-…` icon name"
  end

  @spec tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def tabs(assigns) do
    ~H"""
    <div class="space-y-6">
      <.tab_bar active_tab={@active_tab} target={@target} tabs={@tab} />

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

  @doc """
  Renders just the navigation bar of a tabbed interface, without panels.

  Use this when the panels cannot be slots of a single component — for
  example when they must stay inside one `<form>` whose markup is shared
  with an untabbed layout. Panels rendered elsewhere should carry
  `id={"panel-\#{tab_id}"}` and `role="tabpanel"` to match the buttons'
  ARIA wiring. Clicking a tab sends `switch_tab` with a `tab` value to
  `target`, same as `tabs/1`.

  Each entry in `tabs` is a map with `:id` and `:label`, an optional
  `:icon` (`hero-…` name), and an optional `:error` flag that marks the
  tab with a dot when content inside it needs attention.
  """
  attr :active_tab, :string, required: true
  attr :target, :any, default: nil

  attr :tabs, :list,
    required: true,
    doc: "maps with :id, :label, optional :icon and :error"

  @spec tab_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def tab_bar(assigns) do
    ~H"""
    <div class="bg-white rounded-token-2xl border-2 border-tymeslot-100 p-2 shadow-sm">
      <nav
        role="tablist"
        aria-label={dgettext("common", "Tabs")}
        class="flex flex-wrap gap-2"
      >
        <%= for tab <- @tabs do %>
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
                else: "text-tymeslot-600 hover:bg-tymeslot-50 hover:text-turquoise-700"
              )
            ]}
          >
            <%= if Map.get(tab, :icon) do %>
              <TymeslotWeb.Components.CoreComponents.Icons.icon
                name={tab.icon}
                class="w-5 h-5"
              />
            <% end %>
            <span>{tab.label}</span>
            <span
              :if={Map.get(tab, :error)}
              class="w-2 h-2 shrink-0 rounded-full bg-red-500"
            >
              <span class="sr-only">{dgettext("common", "This tab contains errors")}</span>
            </span>
          </button>
        <% end %>
      </nav>
    </div>
    """
  end
end
