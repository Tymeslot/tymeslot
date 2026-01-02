defmodule TymeslotWeb.Components.DashboardSidebar do
  @moduledoc """
  Left sidebar navigation component for the dashboard.
  Provides navigation links for all dashboard sections.
  """
  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias TymeslotWeb.Components.Icons.IconComponents

  @doc """
  Renders the left sidebar navigation.
  """
  attr :current_action, :atom, required: true
  attr :integration_status, :map, default: %{}
  attr :profile, :any, default: nil

  @spec sidebar(map()) :: Phoenix.LiveView.Rendered.t()
  def sidebar(assigns) do
    ~H"""
    <!-- Mobile Overlay -->
    <div
      id="dashboard-sidebar-overlay"
      class="lg:hidden fixed inset-0 bg-black bg-opacity-50 z-30 dashboard-sidebar-overlay hidden"
      phx-click={
        JS.remove_class("dashboard-sidebar-open", to: "#dashboard-sidebar")
        |> JS.add_class("hidden", to: "#dashboard-sidebar-overlay")
      }
    >
    </div>

    <aside
      id="dashboard-sidebar"
      class="dashboard-sidebar lg:w-64 w-80 h-screen lg:h-full overflow-y-auto lg:flex-shrink-0 lg:relative fixed top-0 left-0 z-40 transform -translate-x-full lg:translate-x-0 transition-transform duration-300 ease-in-out"
    >
      <div class="p-6">
        <!-- Mobile Close Button -->
        <div class="lg:hidden flex justify-end mb-4">
          <button
            class="dashboard-sidebar-close p-2 rounded-lg hover:bg-white/20 transition-colors"
            phx-click={
              JS.remove_class("dashboard-sidebar-open", to: "#dashboard-sidebar")
              |> JS.add_class("hidden", to: "#dashboard-sidebar-overlay")
            }
            aria-label="Close sidebar"
          >
            <svg class="w-6 h-6 text-gray-800" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              >
              </path>
            </svg>
          </button>
        </div>
        
    <!-- Scheduling Link (Mobile and Desktop) -->
        <div class="mb-4 flex gap-2">
          <.link
            :if={LinkAccessPolicy.can_link?(@profile, @integration_status)}
            href={LinkAccessPolicy.scheduling_path(@profile)}
            target="_blank"
            class="dashboard-nav-link flex-1 flex items-center space-x-3 px-4 py-3 text-sm font-medium rounded-lg transition-all duration-200 bg-gradient-to-r from-turquoise-600 to-turquoise-500 text-white hover:from-turquoise-700 hover:to-turquoise-600 shadow-lg hover:shadow-xl transform hover:-translate-y-0.5"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
              >
              </path>
            </svg>
            <span>View Your Scheduling Page</span>
            <svg class="w-4 h-4 ml-auto" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7">
              </path>
            </svg>
          </.link>
          <div
            :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
            class="flex-1 flex items-center space-x-3 px-4 py-3 text-sm font-medium rounded-lg bg-gray-200 text-gray-500 cursor-not-allowed opacity-60"
            title={LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
              >
              </path>
            </svg>
            <span>View Your Scheduling Page</span>
            <svg class="w-4 h-4 ml-auto" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7">
              </path>
            </svg>
          </div>

          <button
            :if={LinkAccessPolicy.can_link?(@profile, @integration_status)}
            type="button"
            phx-click="copy_scheduling_link"
            class="dashboard-nav-link px-3 py-3 rounded-lg transition-all duration-200 bg-gradient-to-r from-turquoise-600 to-turquoise-500 text-white hover:from-turquoise-700 hover:to-turquoise-600 shadow-lg hover:shadow-xl transform hover:-translate-y-0.5 group relative"
            title="Copy link to clipboard"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
              >
              </path>
            </svg>
            <span class="absolute -top-8 left-1/2 transform -translate-x-1/2 bg-gray-900 text-white text-xs px-2 py-1 rounded opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap">
              Copy link
            </span>
          </button>
          <button
            :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
            type="button"
            disabled
            class="px-3 py-3 rounded-lg bg-gray-200 text-gray-500 cursor-not-allowed opacity-60 relative"
            title={LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
              >
              </path>
            </svg>
          </button>
        </div>
        
    <!-- Navigation Links -->
        <nav class="space-y-2">
          <.nav_link patch={~p"/dashboard"} current={@current_action} action={:overview}>
            <IconComponents.icon name={:home} class="w-5 h-5" />
            <span>Overview</span>
          </.nav_link>

          <.nav_link patch={~p"/dashboard/settings"} current={@current_action} action={:settings}>
            <IconComponents.icon name={:user} class="w-5 h-5" />
            <span>Settings</span>
          </.nav_link>

          <.nav_link
            patch={~p"/dashboard/availability"}
            current={@current_action}
            action={:availability}
          >
            <IconComponents.icon name={:calendar} class="w-5 h-5" />
            <span>Availability</span>
          </.nav_link>

          <.nav_link
            patch={~p"/dashboard/meeting-settings"}
            current={@current_action}
            action={:meeting_settings}
            show_notification={not (@integration_status[:has_meeting_types] || false)}
            notification_type="info"
          >
            <IconComponents.icon name={:grid} class="w-5 h-5" />
            <span>Meeting Settings</span>
          </.nav_link>

          <.nav_link
            patch={~p"/dashboard/calendar"}
            current={@current_action}
            action={:calendar}
            show_notification={not (@integration_status[:has_calendar] || false)}
            notification_type="info"
          >
            <IconComponents.icon name={:calendar} class="w-5 h-5" />
            <span>Calendar</span>
          </.nav_link>

          <.nav_link
            patch={~p"/dashboard/video"}
            current={@current_action}
            action={:video}
            show_notification={not (@integration_status[:has_video] || false)}
            notification_type="info"
          >
            <IconComponents.icon name={:video} class="w-5 h-5" />
            <span>Video</span>
          </.nav_link>

          <.nav_link patch={~p"/dashboard/theme"} current={@current_action} action={:theme}>
            <IconComponents.icon name={:paint_brush} class="w-5 h-5" />
            <span>Theme</span>
          </.nav_link>

          <.nav_link patch={~p"/dashboard/meetings"} current={@current_action} action={:meetings}>
            <IconComponents.icon name={:clock} class="w-5 h-5" />
            <span>Meetings</span>
          </.nav_link>

          <.nav_link patch={~p"/dashboard/payment"} current={@current_action} action={:payment}>
            <IconComponents.icon name={:credit_card} class="w-5 h-5" />
            <span>Payment</span>
            <span class="ml-auto text-xs bg-turquoise-100 text-turquoise-700 px-2 py-0.5 rounded-full">
              Coming soon
            </span>
          </.nav_link>
        </nav>
      </div>
    </aside>
    """
  end

  # Private component for navigation links
  attr :patch, :string, required: true
  attr :current, :atom, required: true
  attr :action, :atom, required: true
  attr :show_notification, :boolean, default: false
  attr :notification_type, :string, default: "critical"
  slot :inner_block, required: true

  @spec nav_link(map()) :: Phoenix.LiveView.Rendered.t()
  defp nav_link(assigns) do
    ~H"""
    <.link
      patch={@patch}
      class={[
        "dashboard-nav-link flex items-center space-x-3 px-4 py-3 text-sm font-medium rounded-lg transition-all duration-200",
        if(@current == @action,
          do: "dashboard-nav-link--active",
          else: ""
        )
      ]}
    >
      {render_slot(@inner_block)}
      <!-- Notification Badge -->
      <div
        :if={@show_notification}
        class={[
          "dashboard-nav-notification",
          case @notification_type do
            "warning" -> "dashboard-nav-notification--warning"
            "info" -> "dashboard-nav-notification--info"
            _ -> ""
          end
        ]}
        title="Setup recommended"
      >
        !
      </div>
    </.link>
    """
  end
end
