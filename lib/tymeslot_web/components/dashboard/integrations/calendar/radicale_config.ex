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

  @impl true
  def mount(socket) do
    {:ok, assign_config_defaults(socket)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_config_defaults()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"radicale-config-#{@id}"} class="space-y-6">
      <div class="flex items-center gap-4 mb-2">
        <ProviderIcon.provider_icon provider="radicale" type="calendar" size="large" />
        <div>
          <h3 class="text-xl font-black text-slate-900 tracking-tight">Radicale</h3>
          <p class="text-sm text-slate-500 font-medium">Lightweight CalDAV server integration</p>
        </div>
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
        suggested_name="My Radicale"
        name_placeholder="My Radicale Calendar"
        url_placeholder="https://radicale.example.com:5232"
      />
    </div>
    """
  end
end
