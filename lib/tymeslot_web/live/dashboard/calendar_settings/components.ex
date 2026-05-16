defmodule TymeslotWeb.Dashboard.CalendarSettings.Components do
  @moduledoc """
  Functional components for the calendar settings dashboard.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.{
    BaikalConfig,
    CaldavConfig,
    MailboxOrgConfig,
    NextcloudConfig,
    RadicaleConfig,
    ZimbraConfig
  }

  alias TymeslotWeb.Components.Dashboard.Integrations.ProviderCard
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents
  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Dashboard.CalendarSettings.Helpers

  @doc """
  Renders the configuration view for a specific calendar provider.
  """
  attr :selected_provider, :atom, required: true
  attr :myself, :any, required: true
  attr :security_metadata, :map, required: true
  attr :form_errors, :map, required: true
  attr :form_values, :map, required: true
  attr :discovered_calendars, :list, required: true
  attr :show_calendar_selection, :boolean, required: true
  attr :discovery_credentials, :map, required: true
  attr :is_saving, :boolean, required: true

  @spec config_view(map()) :: Phoenix.LiveView.Rendered.t()
  def config_view(assigns) do
    ~H"""
    <div
      id="calendar-config-view"
      phx-hook="ScrollReset"
      data-action={@selected_provider}
      class="space-y-8"
    >
      <div class="flex items-center gap-6 bg-white p-6 rounded-token-3xl border-2 border-tymeslot-50 shadow-sm">
        <button
          phx-click="back_to_providers"
          phx-target={@myself}
          class="flex items-center gap-2 px-4 py-2 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2.5"
              d="M10 19l-7-7m0 0l7-7m-7 7h18"
            />
          </svg>
          Back
        </button>

        <div class="h-8 w-px bg-tymeslot-100"></div>

        <.section_header
          level={2}
          icon={:calendar}
          title={"Setup #{format_provider_title(@selected_provider)}"}
        />
      </div>

      <div class="card-glass">
        <%= case @selected_provider do %>
          <% :nextcloud -> %>
            <.live_component
              module={NextcloudConfig}
              id="nextcloud-config"
              target={@myself}
              metadata={@security_metadata}
              form_errors={@form_errors}
              form_values={@form_values}
              discovered_calendars={@discovered_calendars}
              show_calendar_selection={@show_calendar_selection}
              discovery_credentials={@discovery_credentials}
              saving={@is_saving}
            />
          <% :radicale -> %>
            <.live_component
              module={RadicaleConfig}
              id="radicale-config"
              target={@myself}
              metadata={@security_metadata}
              form_errors={@form_errors}
              form_values={@form_values}
              discovered_calendars={@discovered_calendars}
              show_calendar_selection={@show_calendar_selection}
              discovery_credentials={@discovery_credentials}
              saving={@is_saving}
            />
          <% :baikal -> %>
            <.live_component
              module={BaikalConfig}
              id="baikal-config"
              target={@myself}
              metadata={@security_metadata}
              form_errors={@form_errors}
              form_values={@form_values}
              discovered_calendars={@discovered_calendars}
              show_calendar_selection={@show_calendar_selection}
              discovery_credentials={@discovery_credentials}
              saving={@is_saving}
            />
          <% :caldav -> %>
            <.live_component
              module={CaldavConfig}
              id="caldav-config"
              target={@myself}
              metadata={@security_metadata}
              form_errors={@form_errors}
              form_values={@form_values}
              discovered_calendars={@discovered_calendars}
              show_calendar_selection={@show_calendar_selection}
              discovery_credentials={@discovery_credentials}
              saving={@is_saving}
            />
          <% :zimbra -> %>
            <.live_component
              module={ZimbraConfig}
              id="zimbra-config"
              target={@myself}
              metadata={@security_metadata}
              form_errors={@form_errors}
              form_values={@form_values}
              discovered_calendars={@discovered_calendars}
              show_calendar_selection={@show_calendar_selection}
              discovery_credentials={@discovery_credentials}
              saving={@is_saving}
            />
          <% :mailbox_org -> %>
            <.live_component
              module={MailboxOrgConfig}
              id="mailbox-org-config"
              target={@myself}
              metadata={@security_metadata}
              form_errors={@form_errors}
              form_values={@form_values}
              discovered_calendars={@discovered_calendars}
              show_calendar_selection={@show_calendar_selection}
              discovery_credentials={@discovery_credentials}
              saving={@is_saving}
            />
          <% _ -> %>
            <p class="text-tymeslot-500 font-medium">
              Configuration form not available for this provider.
            </p>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders the section for already connected calendars.
  """
  attr :integrations, :list, required: true
  attr :testing_integration_id, :any, default: nil
  attr :validating_integration_id, :integer, required: true
  attr :is_refreshing, :boolean, required: true
  attr :myself, :any, required: true
  attr :health_states, :map, default: %{}

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
            <h3 class="text-xl font-black text-tymeslot-900 tracking-tight flex items-center gap-3">
              <div class="w-2 h-2 rounded-full bg-turquoise-500 animate-pulse"></div>
              Active for Conflict Checking
            </h3>
            <p class="text-tymeslot-500 font-medium mt-1 ml-5">
              We'll check these calendars to prevent double bookings automatically.
            </p>
          </div>

          <button
            phx-click="refresh_all_calendars"
            phx-target={@myself}
            class={[
              "flex items-center gap-2 px-5 py-2.5 rounded-token-xl font-bold transition-all border-2 shrink-0 shadow-sm",
              @is_refreshing &&
                "bg-tymeslot-50 text-tymeslot-400 border-tymeslot-100 cursor-not-allowed",
              !@is_refreshing &&
                "bg-white text-turquoise-600 border-turquoise-50 hover:bg-turquoise-50 hover:border-turquoise-100 hover:shadow-turquoise-500/10"
            ]}
            disabled={@is_refreshing}
          >
            <svg
              class={["w-5 h-5", @is_refreshing && "animate-spin"]}
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2.5"
                d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
              />
            </svg>
            {if @is_refreshing, do: "Refreshing...", else: "Refresh All"}
          </button>
        </div>

        <div class="grid grid-cols-1 gap-4">
          <%= for integration <- @active_integrations do %>
            <.calendar_item
              integration={integration}
              validating_integration_id={@validating_integration_id}
              myself={@myself}
              health_state={Map.get(@health_states, integration.id)}
            />
          <% end %>
        </div>
      </div>

      <%!-- Inactive Calendars Section --%>
      <div :if={@inactive_integrations != []} class="space-y-6">
        <div>
          <h3 class="text-xl font-black text-tymeslot-400 tracking-tight flex items-center gap-3">
            <div class="w-2 h-2 rounded-full bg-tymeslot-300"></div>
            Paused Calendars
          </h3>
          <p class="text-tymeslot-400 font-medium mt-1 ml-5">
            These calendars are currently ignored during conflict checking.
          </p>
        </div>

        <div class="grid grid-cols-1 gap-4">
          <%= for integration <- @inactive_integrations do %>
            <.calendar_item
              integration={integration}
              validating_integration_id={@validating_integration_id}
              myself={@myself}
              health_state={Map.get(@health_states, integration.id)}
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders an individual calendar integration item.
  """
  attr :integration, :map, required: true
  attr :validating_integration_id, :integer, required: true
  attr :myself, :any, required: true
  attr :icon_size, :string, default: "compact", values: ["compact", "medium", "large", "mini"]
  attr :health_state, :map, default: nil

  @spec calendar_item(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_item(assigns) do
    provider_name = Helpers.format_provider_name(assigns.integration.provider)

    calendar_list = assigns.integration.calendar_list || []

    no_calendars_selected? =
      assigns.integration.is_active and calendar_list != [] and
        not Enum.any?(calendar_list, &(&1["selected"] || &1[:selected]))

    assigns =
      assigns
      |> assign(:provider_name, provider_name)
      |> assign(
        :display_name,
        if(assigns.integration.name == provider_name,
          do: provider_name,
          else: assigns.integration.name
        )
      )
      |> assign(:no_calendars_selected?, no_calendars_selected?)

    ~H"""
    <div class={[
      "card-glass p-6 transition-all duration-300 hover:shadow-xl group",
      !@integration.is_active && "opacity-75 grayscale-[0.5] hover:grayscale-0"
    ]}>
      <%!-- Top row: info + toggle --%>
      <div class="flex items-start justify-between gap-4">
        <%!-- Info --%>
        <div class="flex items-start gap-4 min-w-0">
          <div class="p-3 bg-tymeslot-50 rounded-2xl group-hover:bg-white group-hover:shadow-md transition-all border border-tymeslot-100 group-hover:border-turquoise-100 flex-shrink-0">
            <ProviderIcon.provider_icon provider={@integration.provider} size={@icon_size} />
          </div>

          <div class="min-w-0 pt-1">
            <div class="flex items-center gap-3 mb-2 flex-wrap">
              <h4 class="text-lg font-black text-tymeslot-900 truncate tracking-tight">
                {@display_name}
              </h4>
              <span
                :if={!@integration.is_active}
                class="px-2 py-0.5 rounded-full bg-tymeslot-100 text-tymeslot-500 text-token-2xs font-black uppercase tracking-widest"
              >
                Paused
              </span>
              <span
                :if={@integration.needs_reauth}
                class="px-2 py-0.5 rounded-full bg-amber-100 text-amber-700 text-token-2xs font-black uppercase tracking-widest"
              >
                Reconnect required
              </span>
              <UIComponents.health_warning_badge :if={
                @health_state && @health_state.status == :unhealthy
              } />
              <UIComponents.no_calendars_badge :if={@no_calendars_selected?} />
            </div>
            <p
              :if={@integration.provider_account_email}
              class="text-sm text-tymeslot-500 truncate -mt-1 mb-1"
            >
              {@integration.provider_account_email}
            </p>

            <p :if={!@integration.is_active} class="text-sm text-tymeslot-400 font-medium italic">
              This integration is currently disabled. Toggle the switch to enable conflict checking.
            </p>
          </div>
        </div>

        <%!-- Actions + toggle (top right) --%>
        <div class="flex items-center gap-1 flex-shrink-0">
          <button
            :if={@integration.provider == "google" && Helpers.needs_scope_upgrade?(@integration)}
            phx-click="upgrade_google_scope"
            phx-value-id={@integration.id}
            phx-target={@myself}
            class="flex items-center gap-2 px-4 py-2 bg-amber-50 text-amber-700 rounded-token-xl font-bold border-2 border-amber-100 hover:bg-amber-100 transition-all shadow-sm shadow-amber-500/5"
            title="Upgrade Google Calendar permissions"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2.5"
                d="M13 10V3L4 14h7v7l9-11h-7z"
              />
            </svg>
            Upgrade
          </button>
          <button
            :if={@integration.provider in ["google", "outlook"]}
            phx-click="connect_provider"
            phx-value-provider={@integration.provider}
            phx-target={@myself}
            class="flex items-center gap-2 px-4 py-2 bg-tymeslot-50 text-tymeslot-700 rounded-token-xl font-bold border-2 border-tymeslot-100 hover:bg-tymeslot-100 transition-all shadow-sm shadow-tymeslot-500/5"
            title="Reconnect integration"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Reconnect
          </button>
          <button
            :if={@integration.provider not in ["google", "outlook"]}
            phx-click="show_reconnect"
            phx-value-id={@integration.id}
            phx-target="#caldav-reconnect-modal"
            class="flex items-center gap-2 px-4 py-2 bg-tymeslot-50 text-tymeslot-700 rounded-token-xl font-bold border-2 border-tymeslot-100 hover:bg-tymeslot-100 transition-all shadow-sm shadow-tymeslot-500/5"
            title="Reconnect integration"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Reconnect
          </button>
          <button
            phx-click="show"
            phx-value-id={@integration.id}
            phx-target="#delete-calendar-modal"
            class="p-2.5 text-tymeslot-300 hover:text-red-500 hover:bg-red-50 rounded-xl transition-all"
            title="Remove Connection"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
              />
            </svg>
          </button>
          <StatusSwitch.status_switch
            id={"calendar-toggle-#{@integration.id}"}
            checked={@integration.is_active}
            on_change="toggle_integration"
            target={@myself}
            phx_value_id={to_string(@integration.id)}
            size={:large}
            class="ring-4 ring-tymeslot-50 group-hover:ring-turquoise-50 transition-all"
          />
        </div>
      </div>

      <%!-- Calendar Selection Grid (full width, active only) --%>
      <div :if={@integration.is_active} class="mt-6">
        <div class="flex items-center gap-2 mb-3">
          <span class="text-token-2xs font-black uppercase tracking-widest text-tymeslot-400">
            Syncing {(@integration.calendar_list || [])
            |> Enum.count(&(&1["selected"] || &1[:selected]))} Calendars
          </span>
          <div class="h-px bg-tymeslot-100 flex-1"></div>
        </div>

        <div class="flex flex-wrap gap-2.5">
          <%= for calendar <- @integration.calendar_list || [] do %>
            <% calendar_id = calendar["id"] || calendar[:id] %>
            <% calendar_name = Calendar.extract_calendar_display_name(calendar) %>
            <% is_selected = calendar["selected"] || calendar[:selected] %>
            <% color = calendar["color"] || calendar[:color] %>

            <button
              phx-click="toggle_calendar_selection"
              phx-value-integration_id={@integration.id}
              phx-value-calendar_id={calendar_id}
              phx-target={@myself}
              class={[
                "inline-flex items-center gap-2.5 px-3.5 py-2 rounded-token-xl border-2 transition-all text-xs font-bold",
                is_selected &&
                  "bg-turquoise-50 border-turquoise-400 text-turquoise-900 shadow-sm shadow-turquoise-500/5",
                !is_selected &&
                  "bg-white border-tymeslot-50 text-tymeslot-400 hover:border-tymeslot-200 hover:bg-tymeslot-50"
              ]}
            >
              <div
                :if={color && is_selected}
                class="w-2.5 h-2.5 rounded-full ring-2 ring-white"
                style={"background-color: #{color}"}
              />
              <span>{calendar_name}</span>
              <span
                :if={calendar["primary"] || calendar[:primary]}
                class="text-[9px] font-black bg-tymeslot-200 px-1.5 py-0.5 rounded text-tymeslot-600 uppercase tracking-tighter"
              >
                Primary
              </span>
              <svg
                :if={is_selected}
                class="w-3.5 h-3.5 text-turquoise-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="3"
                  d="M5 13l4 4L19 7"
                />
              </svg>
            </button>
          <% end %>

          <div
            :if={!@integration.calendar_list || @integration.calendar_list == []}
            class="flex items-center gap-2 text-tymeslot-400 py-2"
          >
            <svg class="w-4 h-4 animate-pulse" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
            <span class="text-xs font-medium italic">
              No calendars found. Try refreshing the integration.
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the grid of available calendar providers.
  """
  attr :available_calendar_providers, :list, required: true
  attr :integrations, :list, default: []
  attr :myself, :any, required: true

  @spec available_providers_section(map()) :: Phoenix.LiveView.Rendered.t()
  def available_providers_section(assigns) do
    {caldav_providers, other_providers} =
      Enum.split_with(assigns.available_calendar_providers, fn descp ->
        ProviderConfig.caldav_based?(descp.type)
      end)

    assigns =
      assigns
      |> assign(:caldav_providers, caldav_providers)
      |> assign(:other_providers, other_providers)

    ~H"""
    <div class="space-y-8 mt-12">
      <div class="max-w-4xl">
        <.section_header level={2} title="Available Providers" />
        <p class="text-tymeslot-500 font-medium text-token-lg ml-1">
          Connect your favorite calendar service to sync availability and automate your scheduling workflow.
        </p>
      </div>

      <div class="space-y-10">
        <div :if={@other_providers != []} class="space-y-5">
          <h3 class="text-token-xl font-black text-tymeslot-800 tracking-tight">
            OAuth Providers
          </h3>
          <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
            <.calendar_provider_card
              :for={descp <- @other_providers}
              descp={descp}
              integrations={@integrations}
              myself={@myself}
            />
          </div>
        </div>

        <div :if={@caldav_providers != []} class="space-y-5">
          <h3 class="text-token-xl font-black text-tymeslot-800 tracking-tight">
            CalDAV Servers
          </h3>
          <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
            <.calendar_provider_card
              :for={descp <- @caldav_providers}
              descp={descp}
              integrations={@integrations}
              myself={@myself}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :descp, :map, required: true
  attr :integrations, :list, required: true
  attr :myself, :any, required: true

  defp calendar_provider_card(assigns) do
    info = Helpers.provider_card_info(assigns.descp.type)
    has_existing = Enum.any?(assigns.integrations, &(&1.provider == info.provider))

    assigns =
      assigns
      |> assign(:info, info)
      |> assign(:has_existing, has_existing)

    ~H"""
    <ProviderCard.provider_card
      provider={@info.provider}
      title={@descp.display_name}
      description={@info.desc}
      button_text={if @has_existing, do: "Add Another Account", else: @info.btn}
      click_event={@info.click}
      target={@myself}
      provider_value={@info.provider}
    />
    """
  end

  # --- Helpers ---

  defp format_provider_title(:nextcloud), do: "Nextcloud"
  defp format_provider_title(:radicale), do: "Radicale"
  defp format_provider_title(:caldav), do: "CalDAV"
  defp format_provider_title(:zimbra), do: "Zimbra"
  defp format_provider_title(:mailbox_org), do: "mailbox.org"
  defp format_provider_title(:baikal), do: "Baikal"
  defp format_provider_title(_provider), do: "Calendar"
end
