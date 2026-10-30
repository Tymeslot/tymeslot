defmodule TymeslotWeb.Dashboard.CalendarSettings.Components do
  @moduledoc """
  Functional components for the calendar settings dashboard: the provider
  configuration view, the free/busy feed section and the connected calendars
  list. Each connected calendar's card is `ConnectionRow`.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.{
    CaldavFamilyConfig,
    ExchangeConfig,
    IcsUrlConfig
  }

  alias TymeslotWeb.Dashboard.CalendarSettings.ConnectionRow

  @doc """
  Renders the configuration view for a specific calendar provider.
  """
  attr :selected_provider, :atom, required: true
  attr :myself, :any, required: true
  attr :form_errors, :map, required: true
  attr :form_values, :map, required: true
  attr :discovered_calendars, :list, required: true
  attr :show_calendar_selection, :boolean, required: true
  attr :discovery_credentials, :map, required: true
  attr :is_saving, :boolean, required: true

  @spec config_view(map()) :: Phoenix.LiveView.Rendered.t()
  def config_view(assigns) do
    assigns =
      assign(
        assigns,
        :caldav_family?,
        assigns.selected_provider in CaldavFamilyConfig.providers()
      )

    ~H"""
    <div id="calendar-config-view" phx-hook="ScrollReset" data-action={@selected_provider}>
      <%= cond do %>
        <% @caldav_family? -> %>
          <CaldavFamilyConfig.caldav_family_config
            provider={@selected_provider}
            target={@myself}
            form_errors={@form_errors}
            form_values={@form_values}
            discovered_calendars={@discovered_calendars}
            show_calendar_selection={@show_calendar_selection}
            discovery_credentials={@discovery_credentials}
            saving={@is_saving}
          />
        <% @selected_provider == :ics_url -> %>
          <.live_component
            module={IcsUrlConfig}
            id="ics-url-config"
            target={@myself}
            form_errors={@form_errors}
            form_values={@form_values}
            saving={@is_saving}
          />
        <% @selected_provider == :exchange -> %>
          <.live_component
            module={ExchangeConfig}
            id="exchange-config"
            target={@myself}
            form_errors={@form_errors}
            form_values={@form_values}
            discovered_calendars={@discovered_calendars}
            show_calendar_selection={@show_calendar_selection}
            discovery_credentials={@discovery_credentials}
            saving={@is_saving}
          />
        <% true -> %>
          <p class="text-tymeslot-500 font-medium">
            {dgettext(
              "dashboard_calendar_settings",
              "Configuration form not available for this provider."
            )}
          </p>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the free/busy feed section: the read-only iCalendar link that
  publishes when the user is busy, and the controls to enable, regenerate, or
  disable it.
  """
  attr :enabled, :boolean, required: true
  attr :url, :string, default: nil
  attr :myself, :any, required: true

  @spec freebusy_section(map()) :: Phoenix.LiveView.Rendered.t()
  def freebusy_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <.subsection_header
        size={:lg}
        level={2}
        icon="hero-link"
        title={dgettext("dashboard_calendar_settings", "Free/busy feed")}
        description={
          dgettext(
            "dashboard_calendar_settings",
            "Share a read-only link that publishes when you're busy (not the event details) as a standard iCalendar feed, so other calendar systems can overlay your availability."
          )
        }
      />

      <.card padding={:sm} class="space-y-3">
        <%= if @enabled do %>
          <code class="block w-full overflow-x-auto rounded-token-md bg-tymeslot-50 px-3 py-2 text-token-sm text-tymeslot-700 select-all">
            {@url}
          </code>
          <div class="flex flex-wrap gap-2">
            <.action_button
              variant={:secondary}
              phx-click="regenerate_freebusy"
              phx-target={@myself}
            >
              {dgettext("dashboard_calendar_settings", "Regenerate link")}
            </.action_button>
            <.action_button variant={:ghost} phx-click="disable_freebusy" phx-target={@myself}>
              {dgettext("dashboard_calendar_settings", "Disable feed")}
            </.action_button>
          </div>
        <% else %>
          <.action_button phx-click="enable_freebusy" phx-target={@myself}>
            {dgettext("dashboard_calendar_settings", "Enable free/busy feed")}
          </.action_button>
        <% end %>
      </.card>
    </section>
    """
  end

  @doc """
  Renders the section for already connected calendars.
  """
  attr :integrations, :list, required: true
  attr :is_refreshing, :boolean, required: true
  attr :myself, :any, required: true
  attr :health_states, :map, default: %{}
  attr :stuck_changes, :map, default: %{}

  @spec connected_calendars_section(map()) :: Phoenix.LiveView.Rendered.t()
  def connected_calendars_section(assigns) do
    # Group integrations by active/inactive
    {active, inactive} = Enum.split_with(assigns.integrations, & &1.is_active)

    assigns =
      assigns
      |> assign(:active_integrations, active)
      |> assign(:inactive_integrations, inactive)

    ~H"""
    <div :if={@integrations != []} class="space-y-12">
      <%!-- Active Calendars Section --%>
      <div :if={@active_integrations != []} class="space-y-6">
        <div class="flex items-center justify-between gap-4 flex-col md:flex-row">
          <div>
            <h2 class="text-token-lg font-semibold text-tymeslot-900 flex items-center gap-3">
              <div class="w-2 h-2 rounded-token-full bg-turquoise-500 animate-pulse"></div>
              {dgettext("dashboard_calendar_settings", "Active for Conflict Checking")}
            </h2>
            <p class="text-tymeslot-500 font-medium mt-1 ml-5">
              {dgettext(
                "dashboard_calendar_settings",
                "We'll check these calendars to prevent double bookings automatically."
              )}
            </p>
          </div>

          <.loading_button
            variant={:secondary}
            icon="hero-arrow-path"
            loading={@is_refreshing}
            loading_text={dgettext("dashboard_calendar_settings", "Refreshing...")}
            class="shrink-0"
            phx-click="refresh_all_calendars"
            phx-target={@myself}
          >
            {dgettext("dashboard_calendar_settings", "Refresh All")}
          </.loading_button>
        </div>

        <.connection_rows
          integrations={@active_integrations}
          myself={@myself}
          health_states={@health_states}
          stuck_changes={@stuck_changes}
        />
      </div>

      <%!-- Inactive Calendars Section --%>
      <div :if={@inactive_integrations != []} class="space-y-6">
        <div>
          <h2 class="text-token-lg font-semibold text-tymeslot-500 flex items-center gap-3">
            <div class="w-2 h-2 rounded-token-full bg-tymeslot-300"></div>
            {dgettext("dashboard_calendar_settings", "Paused Calendars")}
          </h2>
          <p class="text-tymeslot-400 font-medium mt-1 ml-5">
            {dgettext(
              "dashboard_calendar_settings",
              "These calendars are currently ignored during conflict checking."
            )}
          </p>
        </div>

        <.connection_rows
          integrations={@inactive_integrations}
          myself={@myself}
          health_states={@health_states}
          stuck_changes={@stuck_changes}
        />
      </div>
    </div>
    """
  end

  attr :integrations, :list, required: true
  attr :myself, :any, required: true
  attr :health_states, :map, required: true
  attr :stuck_changes, :map, required: true

  defp connection_rows(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-4">
      <%= for integration <- @integrations do %>
        <ConnectionRow.calendar_connection_row
          integration={integration}
          myself={@myself}
          health_state={Map.get(@health_states, integration.id)}
          stuck={Map.get(@stuck_changes, integration.id)}
        />
      <% end %>
    </div>
    """
  end
end
