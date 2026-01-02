defmodule TymeslotWeb.Components.DashboardLayout do
  @moduledoc """
  Shared layout component for all dashboard pages.
  Provides consistent navigation, styling, and user interface elements.
  """
  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.DashboardSidebar
  alias TymeslotWeb.Components.UserDropdownComponent

  @doc """
  Renders the main dashboard layout with left sidebar and top navigation.
  """
  attr :current_user, :any, required: true
  attr :profile, :any, required: true
  attr :current_action, :atom, required: true
  attr :integration_status, :map, default: %{}
  slot :inner_block, required: true

  @spec dashboard_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def dashboard_layout(assigns) do
    ~H"""
    <div class="min-h-screen" id="dashboard-root" phx-hook="ClipboardCopy">
      <!-- Top Navigation - Glass box with container -->
      <.top_navigation current_user={@current_user} profile={@profile} />
      
    <!-- Main Layout Area - Sidebar and Content -->
      <div class="flex relative lg:gap-8">
        <!-- Left Sidebar - Hidden on mobile/tablet, overlay when open -->
        <DashboardSidebar.sidebar
          current_action={@current_action}
          integration_status={@integration_status}
          profile={@profile}
        />
        
    <!-- Main Content Area - Full width on mobile/tablet -->
        <div class="flex-1 min-w-0 w-full lg:ml-0">
          <div class="max-w-6xl mx-auto px-4 lg:px-8">
            <main>
              {render_slot(@inner_block)}
            </main>
          </div>
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

  @spec top_navigation(map()) :: Phoenix.LiveView.Rendered.t()
  def top_navigation(assigns) do
    ~H"""
    <div class="w-full px-4 py-2">
      <nav class="glass-nav mb-2 relative" style="z-index: 50;">
        <div class="w-full px-2 sm:px-4">
          <div class="flex items-center justify-between h-16">
            <!-- Left side: Logo and Mobile Menu Button -->
            <div class="flex items-center space-x-2 sm:space-x-4 -ml-2 sm:-ml-4 flex-1 min-w-0">
              <!-- Mobile Menu Button -->
              <button
                class="lg:hidden dashboard-mobile-menu-toggle flex items-center justify-center w-10 h-10 rounded-lg hover:bg-white/20 transition-colors flex-shrink-0"
                phx-click={
                  JS.toggle_class("dashboard-sidebar-open", to: "#dashboard-sidebar")
                  |> JS.toggle_class("hidden", to: "#dashboard-sidebar-overlay")
                }
                aria-label="Toggle sidebar"
              >
                <svg
                  class="w-6 h-6 text-gray-800"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M4 6h16M4 12h16M4 18h16"
                  >
                  </path>
                </svg>
              </button>
              
    <!-- Logo with Icon and Text -->
              <div class="flex items-center space-x-2 flex-shrink-0">
                <img
                  src="/images/brand/logo.svg"
                  alt="Tymeslot"
                  class="h-8 sm:h-10 lg:h-12 flex-shrink-0"
                />
                <span class="text-xl sm:text-2xl lg:text-3xl font-bold text-gray-800 hidden sm:inline">
                  Tymeslot
                </span>
              </div>
            </div>
            
    <!-- Right side: User dropdown -->
            <div class="relative flex-shrink-0">
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
end
