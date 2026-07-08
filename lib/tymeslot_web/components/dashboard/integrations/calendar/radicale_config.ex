defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.RadicaleConfig do
  @moduledoc """
  Modern component for configuring Radicale calendar integration.
  """
  use TymeslotWeb.Components.Dashboard.Integrations.Calendar.ConfigBase,
    provider: :radicale,
    default_name: "My Radicale"

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Icons.ProviderIcon

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign_config_defaults(socket)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_config_defaults()}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"radicale-config-#{@id}"} class="space-y-6">
      <div class="flex items-start justify-between gap-4 mb-2">
        <div class="flex items-center gap-4">
          <ProviderIcon.provider_icon provider="radicale" type="calendar" size="large" />
          <div>
            <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">Radicale</h3>
            <p class="text-sm text-tymeslot-500 font-medium">
              {dgettext("dashboard_calendar_providers", "Lightweight CalDAV server integration")}
            </p>
          </div>
        </div>
        <a
          href={docs_guide_url("caldav-radicale")}
          target="_blank"
          rel="noopener noreferrer"
          class="shrink-0 flex items-center gap-1.5 text-xs font-semibold text-tymeslot-500 hover:text-tymeslot-700 transition-colors mt-1"
        >
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          {dgettext("dashboard_calendar_providers", "Setup guide")}
        </a>
      </div>

      <SharedForm.config_form
        provider="radicale"
        show_calendar_selection={@show_calendar_selection}
        discovered_calendars={@discovered_calendars}
        discovery_credentials={@discovery_credentials}
        form_errors={@form_errors}
        form_values={@form_values}
        saving={@saving}
        target={@target}
        myself={@myself}
        suggested_name={dgettext("dashboard_calendar_providers", "My Radicale")}
        name_placeholder={dgettext("dashboard_calendar_providers", "My Radicale Calendar")}
        url_placeholder={dgettext("dashboard_calendar_providers", "https://radicale.example.com:5232")}
      />
    </div>
    """
  end
end
