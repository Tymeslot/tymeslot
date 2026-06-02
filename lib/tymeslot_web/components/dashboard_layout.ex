defmodule TymeslotWeb.Components.DashboardLayout do
  @moduledoc """
  Shared layout component for all dashboard pages.
  Provides consistent navigation, styling, and user interface elements.
  """
  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.DashboardSidebar
  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Components.UserDropdownComponent

  @doc """
  Renders the main dashboard layout with left sidebar and top navigation.
  """
  attr :current_user, :any, required: true
  attr :profile, :any, required: true
  attr :current_action, :atom, required: true
  attr :integration_status, :map, default: %{}
  attr :automations_allowed, :boolean, default: true
  attr :payments_allowed, :boolean, default: false
  attr :full_width, :boolean, default: false
  attr :sidebar_extensions, :list, default: []
  attr :unseen_announcements, :list, default: []
  slot :inner_block, required: true

  @spec dashboard_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def dashboard_layout(assigns) do
    ~H"""
    <div
      class={["flex flex-col", if(@full_width, do: "h-screen overflow-hidden")]}
      id="dashboard-root"
      phx-hook="ClipboardCopy"
    >
      <%!-- Feature-announcement carousel. Renders nothing when the list is empty. --%>
      <.live_component
        :if={@unseen_announcements != []}
        module={TymeslotWeb.Components.AnnouncementModalComponent}
        id="announcement-modal"
        announcements={@unseen_announcements}
        current_user={@current_user}
      />

      <%!-- Top Navigation --%>
      <div class={if @full_width, do: "flex-shrink-0"}>
        <.top_navigation
          current_user={@current_user}
          profile={@profile}
          show_sidebar_toggle={mode(@current_action) == :scheduling}
        />
      </div>

      <%!-- Mode Tab Bar --%>
      <.mode_tabs current_action={@current_action} />

      <%!-- Main Layout Area --%>
      <div class={["flex lg:gap-8", if(@full_width, do: "flex-1 overflow-hidden")]}>
        <%= if mode(@current_action) == :scheduling do %>
          <DashboardSidebar.sidebar
            current_action={@current_action}
            integration_status={@integration_status}
            profile={@profile}
            automations_allowed={@automations_allowed}
            payments_allowed={@payments_allowed}
            sidebar_extensions={@sidebar_extensions}
          />
        <% end %>

        <%!-- Main Content Area --%>
        <div
          id="dashboard-content-container"
          class={["flex-1 min-w-0 w-full lg:ml-0", if(@full_width, do: "flex flex-col overflow-hidden")]}
          phx-hook="ScrollReset"
          data-action={@current_action}
        >
          <%= if @full_width do %>
            <main class="flex-1 flex flex-col min-h-0">{render_slot(@inner_block)}</main>
          <% else %>
            <div class="max-w-7xl mx-auto px-4 lg:px-8 pb-8">
              <main>{render_slot(@inner_block)}</main>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the top navigation bar.
  """
  attr :current_user, :any, required: true
  attr :profile, :any, required: true
  attr :show_sidebar_toggle, :boolean, default: true

  @spec top_navigation(map()) :: Phoenix.LiveView.Rendered.t()
  def top_navigation(assigns) do
    ~H"""
    <div class="w-full px-2 sm:px-4 py-4 sm:py-6">
      <nav class="brand-nav relative" style="z-index: 50;">
        <div class="w-full px-1 sm:px-4">
          <div class="flex items-center justify-between gap-2 h-16">
            <%!-- Left side: Logo and Mobile Menu Button --%>
            <div class="flex items-center space-x-2 sm:space-x-4 sm:-ml-4 flex-1 min-w-0">
              <%= if @show_sidebar_toggle do %>
                <%!-- Mobile Menu Button --%>
                <button
                  class="lg:hidden dashboard-mobile-menu-toggle flex items-center justify-center w-12 h-12 rounded-xl bg-tymeslot-50 border-2 border-tymeslot-100 hover:bg-turquoise-50 hover:border-turquoise-100 transition-all flex-shrink-0"
                  phx-click={
                    JS.toggle_class("dashboard-sidebar-open", to: "#dashboard-sidebar")
                    |> JS.toggle_class("hidden", to: "#dashboard-sidebar-overlay")
                  }
                  aria-label="Toggle sidebar"
                >
                  <svg
                    class="w-6 h-6 text-tymeslot-700"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2.5"
                      d="M4 6h16M4 12h16M4 18h16"
                    >
                    </path>
                  </svg>
                </button>
              <% end %>

    <%!-- Logo with Icon and Text --%>
              <div class="flex items-center space-x-3 min-w-0">
                <TymeslotWeb.Components.CoreComponents.logo
                  mode={:full}
                  img_class="h-10 sm:h-16 flex-shrink min-w-0"
                />
              </div>
            </div>

    <%!-- Right side: User dropdown --%>
            <div class="relative flex-shrink-0" data-tour="user-menu">
              <.live_component
                module={UserDropdownComponent}
                id="user-dropdown"
                current_user={@current_user}
                profile={@profile}
              />
            </div>
          </div>
        </div>
      </nav>
    </div>
    """
  end

  attr :current_action, :atom, required: true

  @spec mode_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  defp mode_tabs(assigns) do
    ~H"""
    <div class="mode-tab-bar" data-testid="mode-tab-bar" data-tour="mode-tabs">
      <div class="flex items-stretch w-full gap-2">
        <.link
          patch={~p"/dashboard"}
          class={["mode-tab flex-1 justify-center", if(mode(@current_action) == :scheduling, do: "mode-tab--active", else: "mode-tab--inactive")]}
          data-testid="mode-tab-scheduling"
        >
          <IconComponents.icon name={:grid} class="w-4 h-4" />
          Scheduling
        </.link>

        <.link
          patch={~p"/dashboard/calendar"}
          class={["mode-tab flex-1 justify-center", if(mode(@current_action) == :calendar, do: "mode-tab--active", else: "mode-tab--inactive")]}
          data-testid="mode-tab-calendar"
        >
          <IconComponents.icon name={:calendar} class="w-4 h-4" />
          Calendar
        </.link>
      </div>
    </div>
    """
  end

  defp mode(:calendar), do: :calendar
  defp mode(_tab), do: :scheduling
end
