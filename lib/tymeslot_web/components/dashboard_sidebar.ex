defmodule TymeslotWeb.Components.DashboardSidebar do
  @moduledoc """
  Left sidebar navigation component for the dashboard.
  Provides navigation links for all dashboard sections.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Analytics
  alias Tymeslot.Scheduling.LinkAccessPolicy

  # Calendars, video and payments now share a single "Integrations" nav item.
  # The item is marked current for the hub action and for every legacy action
  # that redirects into it, so the highlight is correct even mid-redirect.
  @integration_actions [:integrations, :calendar_integration, :video_integration, :payments]

  @doc """
  Renders the left sidebar navigation.
  """
  attr :current_action, :atom, required: true
  attr :integration_status, :map, default: %{}
  attr :profile, :any, default: nil
  attr :automations_allowed, :boolean, default: true
  attr :analytics_allowed, :boolean, default: true
  attr :sidebar_extensions, :list, default: []

  attr :rail_toggle, :boolean,
    default: false,
    doc: "offer the control that switches between the full menu and the icon rail"

  attr :rail, :boolean,
    default: false,
    doc: "from the lg breakpoint, show the menu as a narrow column of icons"

  @spec sidebar(map()) :: Phoenix.LiveView.Rendered.t()
  def sidebar(assigns) do
    ~H"""
    <%!-- Mobile Overlay --%>
    <div
      id="dashboard-sidebar-overlay"
      class="lg:hidden fixed inset-0 bg-black/50 z-30 dashboard-sidebar-overlay hidden"
      phx-click={dismiss_sidebar_js()}
    >
    </div>

    <aside
      id="dashboard-sidebar"
      data-tour="sidebar-nav"
      phx-hook="SidebarEscape"
      data-dismiss={dismiss_sidebar_js()}
      class={[
        "dashboard-sidebar",
        if(@rail, do: "dashboard-sidebar--rail lg:w-20", else: "lg:w-64"),
        "w-80 h-screen lg:h-full overflow-y-auto overscroll-contain [scrollbar-width:thin] lg:shrink-0 lg:relative fixed top-0 left-0 z-40 transform -translate-x-full lg:translate-x-0 transition-transform duration-300 ease-in-out"
      ]}
    >
      <div class="p-6 lg:px-4 lg:pt-4">
        <%!-- Mobile Close Button --%>
        <div class="lg:hidden flex items-center justify-between mb-6">
          <TymeslotWeb.Components.CoreComponents.Brand.logo mode={:full} img_class="h-12" />
          <button
            type="button"
            class="dashboard-sidebar-close p-3 rounded-token-xl bg-tymeslot-50 border-2 border-tymeslot-100 hover:bg-red-50 hover:border-red-100 transition-all"
            phx-click={dismiss_sidebar_js()}
            aria-label={dgettext("dashboard_common", "Close sidebar")}
          >
            <.icon name="hero-x-mark" class="w-6 h-6 text-tymeslot-700" />
          </button>
        </div>

        <%!-- Scheduling Link (Mobile and Desktop) --%>
        <div class="mb-6 lg:mb-4 flex flex-wrap gap-2">
          <.link
            :if={LinkAccessPolicy.can_link?(@profile, @integration_status)}
            href={LinkAccessPolicy.scheduling_path(@profile)}
            target="_blank"
            class="dashboard-nav-link flex-1 min-w-0 bg-linear-to-br from-turquoise-600 to-cyan-600 text-white hover:text-white hover:translate-x-0 shadow-lg shadow-turquoise-500/30 hover:shadow-xl hover:shadow-turquoise-500/40 hover:from-turquoise-700 hover:to-cyan-700 group"
          >
            <.icon name="hero-arrow-top-right-on-square" class="w-5 h-5 shrink-0 text-white" />
            <span class="dashboard-nav-label text-white min-w-0 leading-tight wrap-break-word">{dgettext(
              "dashboard_common",
              "View Page"
            )}</span>
          </.link>
          <div
            :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
            role="link"
            aria-disabled="true"
            aria-describedby="scheduling-link-disabled-reason"
            class="flex-1 min-w-0 flex items-center space-x-3 px-4 py-4 text-sm font-bold rounded-token-2xl bg-tymeslot-100 text-tymeslot-400 cursor-not-allowed opacity-60 border-2 border-tymeslot-200"
          >
            <.icon name="hero-arrow-top-right-on-square" class="w-5 h-5 shrink-0" />
            <span class="dashboard-nav-label min-w-0 leading-tight wrap-break-word">{dgettext(
              "dashboard_common",
              "View Page"
            )}</span>
          </div>

          <.tooltip
            :if={LinkAccessPolicy.can_link?(@profile, @integration_status)}
            text={dgettext("dashboard_common", "Copy link to clipboard")}
          >
            <button
              id="copy-scheduling-link"
              type="button"
              phx-hook="CopyOnClick"
              phx-click="booking_link_copied"
              phx-value-channel="sidebar"
              data-copy-text={"#{TymeslotWeb.Endpoint.url()}#{LinkAccessPolicy.scheduling_path(@profile)}"}
              data-copy-feedback={
                dgettext("dashboard_common", "Scheduling link copied to clipboard!")
              }
              class="dashboard-nav-link shrink-0 border-2 border-tymeslot-100 hover:border-turquoise-400 hover:translate-x-0 shadow-sm hover:shadow-md group"
              aria-label={dgettext("dashboard_common", "Copy link to clipboard")}
            >
              <.icon name="hero-clipboard" class="w-5 h-5" />
            </button>
          </.tooltip>
          <%!-- `aria-disabled` rather than `disabled`, so the control stays
                focusable and the reason under the row reaches keyboard and
                screen reader users. The accessible name stays the action. --%>
          <button
            :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
            id="copy-scheduling-link-disabled"
            type="button"
            aria-disabled="true"
            aria-describedby="scheduling-link-disabled-reason"
            class="shrink-0 px-4 py-4 rounded-token-2xl bg-tymeslot-100 text-tymeslot-400 border-2 border-tymeslot-200 cursor-not-allowed opacity-60"
            aria-label={dgettext("dashboard_common", "Copy link to clipboard")}
          >
            <.icon name="hero-clipboard" class="w-5 h-5" />
          </button>
          <p
            :if={!LinkAccessPolicy.can_link?(@profile, @integration_status)}
            id="scheduling-link-disabled-reason"
            class="dashboard-nav-label basis-full text-token-xs text-tymeslot-500"
          >
            {LinkAccessPolicy.disabled_tooltip(@profile, @integration_status)}
          </p>
        </div>

        <%!-- Switches the menu between full width and the icon rail. Desktop
              only: below lg the menu is a drawer and always shows labels. --%>
        <.tooltip :if={@rail_toggle} text={rail_toggle_label(@rail)}>
          <button
            id="dashboard-sidebar-rail-toggle"
            type="button"
            phx-click="nav:toggle_rail"
            class="dashboard-nav-link dashboard-sidebar-rail-toggle hidden lg:flex w-full text-tymeslot-500"
          >
            <.icon
              name={if @rail, do: "hero-chevron-double-right", else: "hero-chevron-double-left"}
              class="w-5 h-5"
            />
            <span class="dashboard-nav-label">{rail_toggle_label(@rail)}</span>
          </button>
        </.tooltip>

        <%!-- Navigation Links --%>
        <nav class="space-y-3 mt-6 lg:mt-4">
          <div>
            <div class="dashboard-nav-section-title">{dgettext("dashboard_common", "General")}</div>
            <div class="space-y-0">
              <.nav_link
                patch={~p"/dashboard/overview"}
                current={@current_action}
                action={:overview}
                icon="hero-home"
                label={dgettext("dashboard_common", "Overview")}
                rail={@rail}
              />

              <.nav_link
                patch={~p"/dashboard"}
                current={@current_action}
                action={:calendar}
                icon="hero-calendar-days"
                label={dgettext("dashboard_common", "Calendar")}
                rail={@rail}
              />

              <.nav_link
                patch={~p"/dashboard/meetings"}
                current={@current_action}
                action={:meetings}
                icon="hero-clock"
                label={dgettext("dashboard_common", "Meetings")}
                rail={@rail}
              />

              <.nav_link
                :if={Analytics.enabled?()}
                patch={~p"/dashboard/analytics"}
                current={@current_action}
                action={:analytics}
                locked={!@analytics_allowed}
                icon="hero-chart-bar"
                label={dgettext("dashboard_common", "Analytics")}
                rail={@rail}
              >
                <:trailing>
                  <.pro_badge :if={!@analytics_allowed} data-testid="analytics-pro-badge" />
                </:trailing>
              </.nav_link>
            </div>
          </div>

          <div>
            <div class="dashboard-nav-section-title">
              {dgettext("dashboard_common", "Scheduling")}
            </div>
            <div class="space-y-0">
              <.nav_link
                patch={~p"/dashboard/meeting-settings"}
                current={@current_action}
                action={:meeting_settings}
                setup_reminder={meeting_types_setup_reminder(@integration_status)}
                icon="hero-squares-2x2"
                label={dgettext("dashboard_common", "Meeting Types")}
                rail={@rail}
              />

              <.nav_link
                patch={~p"/dashboard/locations"}
                current={@current_action}
                action={:locations}
                icon="hero-map-pin"
                label={dgettext("dashboard_common", "Locations")}
                rail={@rail}
              />

              <.nav_link
                patch={~p"/dashboard/availability"}
                current={@current_action}
                action={:availability}
                icon="hero-adjustments-horizontal"
                label={dgettext("dashboard_common", "Availability")}
                rail={@rail}
              />

              <.nav_link
                patch={~p"/dashboard/polls"}
                current={@current_action}
                action={:polls}
                icon="hero-hand-raised"
                label={dgettext("dashboard_common", "Polls")}
                rail={@rail}
              />

              <.nav_link
                patch={~p"/dashboard/pages"}
                current={
                  if @current_action == :theme_customization, do: :theme, else: @current_action
                }
                action={:theme}
                icon="hero-rectangle-stack"
                label={dgettext("dashboard_common", "Booking pages")}
                rail={@rail}
              />

              <.nav_link
                patch={~p"/dashboard/languages"}
                current={@current_action}
                action={:languages}
                icon="hero-language"
                label={dgettext("dashboard_common", "Languages")}
                rail={@rail}
              />
            </div>
          </div>

          <div>
            <div class="dashboard-nav-section-title">
              {dgettext("dashboard_common", "Integrations")}
            </div>
            <div class="space-y-0">
              <.nav_link
                patch={~p"/dashboard/integrations"}
                current={integrations_current(@current_action)}
                action={:integrations}
                setup_reminder={integrations_setup_reminder(@integration_status)}
                icon="hero-puzzle-piece"
                label={dgettext("dashboard_common", "Integrations")}
                rail={@rail}
              />
            </div>
          </div>

          <div>
            <div class="dashboard-nav-section-title">
              {dgettext("dashboard_common", "Distribution")}
            </div>
            <div class="space-y-0">
              <.nav_link
                patch={~p"/dashboard/embed"}
                current={@current_action}
                action={:embed}
                icon="hero-code-bracket"
                label={dgettext("dashboard_common", "Embed & Share")}
                rail={@rail}
              />
            </div>
          </div>

          <div>
            <div class="dashboard-nav-section-title">{dgettext("dashboard_common", "Account")}</div>
            <div class="space-y-0">
              <.nav_link
                patch={~p"/dashboard/settings"}
                current={@current_action}
                action={:settings}
                icon="hero-user"
                label={dgettext("dashboard_common", "Profile")}
                rail={@rail}
              />

              <.nav_link
                patch={~p"/dashboard/automation"}
                current={@current_action}
                action={:automation}
                locked={!@automations_allowed}
                icon="hero-bolt"
                label={dgettext("dashboard_common", "Automation")}
                rail={@rail}
              >
                <:trailing>
                  <.pro_badge :if={!@automations_allowed} data-testid="automation-pro-badge" />
                </:trailing>
              </.nav_link>

              <.nav_link
                :for={ext <- @sidebar_extensions}
                navigate={ext.path}
                current={@current_action}
                action={ext.action}
                icon={ext.icon}
                label={extension_label(ext.label)}
                rail={@rail}
              />
            </div>
          </div>
        </nav>
      </div>
    </aside>
    """
  end

  # Sidebar extensions supply their labels as English strings via config. Each
  # extension owns its labels' translations in its own gettext catalogue, so the
  # {backend, domain} to localise through is configurable (:dashboard_extension_gettext)
  # and defaults to Core's shared nav domain. An unknown label falls back to the
  # English text unchanged.
  defp extension_label(label) do
    {backend, domain} =
      Application.get_env(
        :tymeslot,
        :dashboard_extension_gettext,
        {TymeslotWeb.Gettext, "dashboard_common"}
      )

    Gettext.dgettext(backend, domain, label)
  end

  # Collapses the hub action and every legacy action that redirects into it to
  # `:integrations` so the merged nav item highlights for all of them.
  defp integrations_current(action) when action in @integration_actions, do: :integrations
  defp integrations_current(action), do: action

  # The single Integrations item covers both calendar and video, so it flags
  # "needs attention" when either is still unconnected. Which of the two is
  # outstanding has to travel with the marker: once one is connected, a badge
  # that only says "something is missing" reads as if the connection never
  # registered.
  #
  # A calendar whose credentials were refused outranks both: the setup is done,
  # but the booking page offers no times until it is reconnected.
  defp integrations_setup_reminder(%{refused_calendars: [_first | _rest] = names}),
    do:
      dgettext(
        "dashboard_common",
        "Reconnect %{names}: until you do, your booking page may not take bookings",
        names: Enum.join(names, ", ")
      )

  defp integrations_setup_reminder(status) do
    missing =
      for {kind, key} <- [calendar: :has_calendar, video: :has_video],
          not Map.get(status, key, false),
          do: kind

    integration_setup_title(missing)
  end

  defp integration_setup_title([]), do: nil

  defp integration_setup_title([:calendar]),
    do: dgettext("dashboard_common", "Connect a calendar to finish setup")

  defp integration_setup_title([:video]),
    do: dgettext("dashboard_common", "Connect a video provider to finish setup")

  defp integration_setup_title([:calendar, :video]),
    do: dgettext("dashboard_common", "Connect a calendar and a video provider to finish setup")

  defp meeting_types_setup_reminder(%{has_meeting_types: true}), do: nil

  defp meeting_types_setup_reminder(_status),
    do: dgettext("dashboard_common", "Add a meeting type so guests have something to book")

  defp close_sidebar_js do
    %JS{}
    |> JS.remove_class("dashboard-sidebar-open", to: "#dashboard-sidebar")
    |> JS.add_class("hidden", to: "#dashboard-sidebar-overlay")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#dashboard-sidebar-toggle")
  end

  # Dismissing the drawer (Escape, the close button, the backdrop) hands focus
  # back to the menu toggle that opened it. Following a nav link does not: that
  # navigates, and focus belongs to the new page.
  defp dismiss_sidebar_js do
    JS.focus(close_sidebar_js(), to: "#dashboard-sidebar-toggle")
  end

  # Private component for navigation links
  attr :patch, :string, default: nil
  attr :navigate, :string, default: nil
  attr :current, :atom, required: true
  attr :action, :atom, required: true

  attr :setup_reminder, :string,
    default: nil,
    doc: "Why the row carries a setup dot, or nil for no dot."

  attr :locked, :boolean, default: false
  attr :icon, :string, required: true
  attr :label, :string, required: true

  attr :rail, :boolean,
    default: false,
    doc: "the menu is an icon rail: the label moves into the tooltip"

  attr :rest, :global
  slot :trailing, doc: "shown after the label, such as the Pro badge"

  @spec nav_link(map()) :: Phoenix.LiveView.Rendered.t()
  defp nav_link(assigns) do
    ~H"""
    <.tooltip text={nav_tooltip(@rail, @label, @setup_reminder)}>
      <.link
        patch={@patch}
        navigate={@navigate}
        phx-click={close_sidebar_js()}
        aria-current={if @current == @action, do: "page"}
        {@rest}
        class={[
          "dashboard-nav-link",
          if(@current == @action, do: "dashboard-nav-link--active", else: ""),
          if(@locked, do: "opacity-75", else: "")
        ]}
      >
        <.icon name={@icon} class="w-5 h-5" />
        <span class="dashboard-nav-label">{@label}</span>
        <%!-- The rail has no room for a badge; the dimmed row says it is locked. --%>
        <%= if !@rail do %>
          {render_slot(@trailing)}
        <% end %>
        <%!-- Setup reminder: a small dot and nothing more, so the row never reads
            as a second selected item. Only the current section is styled as
            active. The reason is a tooltip on the row for pointers and
            keyboards, and screen-reader-only text after the label, led by a
            comma so it is read as a pause rather than run into the label. --%>
        <span :if={@setup_reminder} class="dashboard-nav-notification">
          <span
            class={[
              "block w-2 h-2 rounded-token-full",
              if(@current == @action, do: "bg-white", else: "bg-turquoise-600")
            ]}
            aria-hidden="true"
          ></span>
          <span class="sr-only">, {@setup_reminder}</span>
        </span>
      </.link>
    </.tooltip>
    """
  end

  defp rail_toggle_label(true), do: dgettext("dashboard_common", "Expand menu")
  defp rail_toggle_label(false), do: dgettext("dashboard_common", "Collapse menu")

  # In the rail the label is hidden, so the tooltip carries it, ahead of any
  # setup reminder; the full menu shows the label and keeps the reminder alone.
  defp nav_tooltip(false, _label, reminder), do: reminder
  defp nav_tooltip(true, label, nil), do: label
  defp nav_tooltip(true, label, reminder), do: "#{label}: #{reminder}"

  # Renders a "Pro" badge for gated features.
  attr :class, :string, default: nil
  attr :rest, :global

  defp pro_badge(assigns) do
    ~H"""
    <.pill tone={:brand} uppercase class={["ml-auto", @class]} {@rest}>
      {dgettext("dashboard_common", "Pro")}
    </.pill>
    """
  end
end
