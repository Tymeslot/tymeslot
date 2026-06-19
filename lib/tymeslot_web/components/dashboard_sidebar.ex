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
  attr :automations_allowed, :boolean, default: true
  attr :payments_allowed, :boolean, default: false
  attr :sidebar_extensions, :list, default: []

  @spec sidebar(map()) :: Phoenix.LiveView.Rendered.t()
  def sidebar(assigns) do
    ~H"""
    <%!-- Mobile Overlay --%>
    <div
      id="dashboard-sidebar-overlay"
      class="lg:hidden fixed inset-0 bg-black/50 z-30 dashboard-sidebar-overlay hidden"
      phx-click={close_sidebar_js()}
    >
    </div>

    <aside
      id="dashboard-sidebar"
      data-tour="sidebar-nav"
      class="dashboard-sidebar lg:w-64 w-80 h-screen lg:h-full overflow-y-auto lg:shrink-0 lg:relative fixed top-0 left-0 z-40 transform -translate-x-full lg:translate-x-0 transition-transform duration-300 ease-in-out"
    >
      <div class="p-6">
        <%!-- Mobile Close Button --%>
        <div class="lg:hidden flex items-center justify-between mb-6">
          <TymeslotWeb.Components.CoreComponents.logo mode={:full} img_class="h-12" />
          <button
            class="dashboard-sidebar-close p-3 rounded-xl bg-tymeslot-50 border-2 border-tymeslot-100 hover:bg-red-50 hover:border-red-100 transition-all"
            phx-click={close_sidebar_js()}
            aria-label="Close sidebar"
          >
            <IconComponents.icon name={:x_mark} class="w-6 h-6 text-tymeslot-700" />
          </button>
        </div>

    <%!-- Scheduling Link (Mobile and Desktop) --%>
        <div class="mb-6 flex gap-2">
          <.link
            :if={LinkAccessPolicy.can_link?(@profile, @integration_status)}
            href={LinkAccessPolicy.scheduling_path(@profile)}
            target="_blank"
            class="dashboard-nav-link flex-1 flex items-center space-x-3 px-4 py-4 text-sm font-black rounded-2xl transition-all duration-300 bg-linear-to-br from-turquoise-600 to-cyan-600 text-white hover:text-white hover:translate-x-0 shadow-lg shadow-turquoise-500/30 hover:shadow-xl hover:shadow-turquoise-500/40 hover:from-turquoise-700 hover:to-cyan-700 group"
          >
            <IconComponents.icon name={:external_link} class="w-5 h-5 text-white" />
            <span class="text-white">View Page</span>
          </.link>
          <div
            :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
            class="flex-1 flex items-center space-x-3 px-4 py-4 text-sm font-bold rounded-2xl bg-tymeslot-100 text-tymeslot-400 cursor-not-allowed opacity-60 border-2 border-tymeslot-200"
            title={LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
          >
            <IconComponents.icon name={:external_link} class="w-5 h-5" />
            <span>View Page</span>
          </div>

          <button
            :if={LinkAccessPolicy.can_link?(@profile, @integration_status)}
            id="copy-scheduling-link"
            type="button"
            phx-hook="CopyOnClick"
            data-copy-text={"#{TymeslotWeb.Endpoint.url()}#{LinkAccessPolicy.scheduling_path(@profile)}"}
            data-copy-feedback="Scheduling link copied to clipboard!"
            class="dashboard-nav-link px-4 py-4 rounded-2xl transition-all duration-300 bg-white border-2 border-tymeslot-100 text-tymeslot-700 hover:border-turquoise-400 hover:text-turquoise-700 hover:translate-x-0 shadow-sm hover:shadow-md group"
            title="Copy link to clipboard"
          >
            <IconComponents.icon name={:clipboard} class="w-5 h-5" />
          </button>
          <button
            :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
            type="button"
            disabled
            class="px-3 py-3 rounded-lg bg-tymeslot-200 text-tymeslot-500 cursor-not-allowed opacity-60 relative"
            title={LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
          >
            <IconComponents.icon name={:clipboard} class="w-5 h-5" />
          </button>
        </div>

    <%!-- Navigation Links --%>
        <nav class="space-y-3 mt-6">
          <div>
            <div class="dashboard-nav-section-title">General</div>
            <div class="space-y-0">
              <.nav_link patch={~p"/dashboard"} current={@current_action} action={:overview}>
                <IconComponents.icon name={:home} class="w-5 h-5" />
                <span>Overview</span>
              </.nav_link>

              <.nav_link patch={~p"/dashboard/meetings"} current={@current_action} action={:meetings}>
                <IconComponents.icon name={:clock} class="w-5 h-5" />
                <span>Meetings</span>
              </.nav_link>

              <.nav_link
                patch={~p"/dashboard/analytics"}
                current={@current_action}
                action={:analytics}
              >
                <IconComponents.icon name={:bar_chart} class="w-5 h-5" />
                <span>Analytics</span>
              </.nav_link>

            </div>
          </div>

          <div>
            <div class="dashboard-nav-section-title">Scheduling</div>
            <div class="space-y-0">
              <.nav_link
                patch={~p"/dashboard/meeting-settings"}
                current={@current_action}
                action={:meeting_settings}
                show_notification={not (@integration_status[:has_meeting_types] || false)}
                notification_type="info"
              >
                <IconComponents.icon name={:grid} class="w-5 h-5" />
                <span>Meeting Types</span>
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
                patch={~p"/dashboard/theme"}
                current={if @current_action == :theme_customization, do: :theme, else: @current_action}
                action={:theme}
              >
                <IconComponents.icon name={:paint_brush} class="w-5 h-5" />
                <span>Theme</span>
              </.nav_link>
            </div>
          </div>

          <div>
            <div class="dashboard-nav-section-title">Integrations</div>
            <div class="space-y-0">
              <.nav_link
                patch={~p"/dashboard/calendar-integration"}
                current={@current_action}
                action={:calendar_integration}
                show_notification={not (@integration_status[:has_calendar] || false)}
                notification_type="info"
              >
                <IconComponents.icon name={:calendar} class="w-5 h-5" />
                <span>Calendar</span>
              </.nav_link>

              <.nav_link
                patch={~p"/dashboard/video-integration"}
                current={@current_action}
                action={:video_integration}
                show_notification={not (@integration_status[:has_video] || false)}
                notification_type="info"
              >
                <IconComponents.icon name={:video} class="w-5 h-5" />
                <span>Video</span>
              </.nav_link>
            </div>
          </div>

          <div>
            <div class="dashboard-nav-section-title">Distribution</div>
            <div class="space-y-0">
              <.nav_link patch={~p"/dashboard/embed"} current={@current_action} action={:embed}>
                <IconComponents.icon name={:code} class="w-5 h-5" />
                <span>Embed & Share</span>
              </.nav_link>
            </div>
          </div>

          <div>
            <div class="dashboard-nav-section-title">Account</div>
            <div class="space-y-0">
              <.nav_link patch={~p"/dashboard/settings"} current={@current_action} action={:settings}>
                <IconComponents.icon name={:user} class="w-5 h-5" />
                <span>Profile</span>
              </.nav_link>

              <.nav_link
                patch={~p"/dashboard/automation"}
                current={@current_action}
                action={:automation}
                locked={!@automations_allowed}>
                <IconComponents.icon name={:bolt} class="w-5 h-5" />
                <span>Automation</span>
                <.pro_badge :if={!@automations_allowed} data-testid="automation-pro-badge" />
              </.nav_link>

              <.nav_link
                :if={@payments_allowed}
                patch={~p"/dashboard/payments"}
                current={@current_action}
                action={:payments}
                data-testid="payments-nav-link"
              >
                <IconComponents.icon name={:credit_card} class="w-5 h-5" />
                <span>Payments</span>
              </.nav_link>

              <.nav_link
                :for={ext <- @sidebar_extensions}
                navigate={ext.path}
                current={@current_action}
                action={ext.action}
              >
                <IconComponents.icon name={ext.icon} class="w-5 h-5" />
                <span>{ext.label}</span>
              </.nav_link>
            </div>
          </div>
        </nav>
      </div>
    </aside>
    """
  end

  @spec close_sidebar_js() :: Phoenix.LiveView.JS.t()
  def close_sidebar_js do
    %JS{}
    |> JS.remove_class("dashboard-sidebar-open", to: "#dashboard-sidebar")
    |> JS.add_class("hidden", to: "#dashboard-sidebar-overlay")
  end

  # Private component for navigation links
  attr :patch, :string, default: nil
  attr :navigate, :string, default: nil
  attr :current, :atom, required: true
  attr :action, :atom, required: true
  attr :show_notification, :boolean, default: false
  attr :notification_type, :string, default: "critical"
  attr :locked, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  @spec nav_link(map()) :: Phoenix.LiveView.Rendered.t()
  defp nav_link(assigns) do
    ~H"""
    <.link
      patch={@patch}
      navigate={@navigate}
      phx-click={close_sidebar_js()}
      {@rest}
      class={[
        "dashboard-nav-link flex items-center space-x-3 px-4 py-2 text-sm font-medium rounded-lg transition-all duration-200",
        if(@current == @action,
          do: "dashboard-nav-link--active",
          else: ""
        ),
        if(@locked, do: "opacity-75", else: "")
      ]}
    >
      {render_slot(@inner_block)}
      <%!-- Notification Badge --%>
      <div
        :if={@show_notification}
        class={[
          "dashboard-nav-notification",
          case @notification_type do
            "warning" -> "dashboard-nav-notification--warning"
            "info" -> "dashboard-nav-notification--info"
            _other -> ""
          end
        ]}
        title="Setup recommended"
      >
        !
      </div>
    </.link>
    """
  end

  # Renders a "Pro" badge for gated features.
  attr :class, :string, default: nil
  attr :rest, :global

  defp pro_badge(assigns) do
    ~H"""
    <span
      class={[
        "ml-auto text-xs bg-purple-100 text-purple-700 px-2 py-0.5 rounded font-semibold",
        @class
      ]}
      {@rest}
    >
      Pro
    </span>
    """
  end
end
