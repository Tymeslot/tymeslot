defmodule TymeslotWeb.Dashboard.CalendarSettings.Components do
  @moduledoc """
  Functional components for the calendar settings dashboard.
  """
  use TymeslotWeb, :html

  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.TokenUtils

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.{
    AppleConfig,
    BaikalConfig,
    CaldavConfig,
    MailboxOrgConfig,
    NextcloudConfig,
    RadicaleConfig,
    ZimbraConfig
  }

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionRow
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
          icon="hero-calendar-days"
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
          <% :apple -> %>
            <.live_component
              module={AppleConfig}
              id="apple-config"
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
  attr :is_refreshing, :boolean, required: true
  attr :myself, :any, required: true
  attr :health_states, :map, default: %{}
  attr :expanded_rows, :any, default: nil

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
            <.calendar_connection_row
              integration={integration}
              expanded?={row_expanded?(@expanded_rows, integration.id)}
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
            <.calendar_connection_row
              integration={integration}
              expanded?={row_expanded?(@expanded_rows, integration.id)}
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
  Renders a single connected calendar integration as a shared
  `connection_row`: status-first header with a one-line summary, the
  calendar-selection chip grid in the expandable `:detail` slot, and the
  upgrade/delete controls in the `:actions` slot. When the integration needs
  re-authentication (`needs_reauth`), the Reconnect control is surfaced on the
  collapsed header via `:header_action` instead of the expanded actions, so the
  fix is one click away without opening the row.
  """
  attr :integration, :map, required: true
  attr :expanded?, :boolean, default: false
  attr :myself, :any, required: true
  attr :health_state, :map, default: nil

  @spec calendar_connection_row(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_connection_row(assigns) do
    integration = assigns.integration
    provider_name = Helpers.format_provider_name(integration.provider)
    calendar_list = integration.calendar_list || []

    assigns =
      assigns
      |> assign(:calendar_list, calendar_list)
      |> assign(:status, integration_status(integration, assigns.health_state))
      |> assign(:summary, calendar_summary(integration))
      |> assign(
        :display_name,
        if(integration.name == provider_name, do: provider_name, else: integration.name)
      )

    ~H"""
    <ConnectionRow.connection_row
      id={to_string(@integration.id)}
      icon={@integration.provider}
      icon_type={:calendar}
      title={@display_name}
      summary={@summary}
      status={@status}
      active?={@integration.is_active}
      expanded?={@expanded?}
      toggle_event="toggle_integration"
      myself={@myself}
    >
      <:header_action :if={@integration.needs_reauth}>
        <button
          :if={@integration.provider in ["google", "outlook"]}
          phx-click="connect_provider"
          phx-value-provider={@integration.provider}
          phx-target={@myself}
          class="flex items-center gap-1.5 px-3 py-1.5 bg-amber-50 text-amber-700 rounded-token-xl font-bold border-2 border-amber-100 hover:bg-amber-100 transition-all shadow-sm shadow-amber-500/5"
          title="Reconnect integration"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Reconnect
        </button>
        <button
          :if={@integration.provider not in ["google", "outlook"]}
          phx-click="show_reconnect"
          phx-value-id={@integration.id}
          phx-target="#caldav-reconnect-modal"
          class="flex items-center gap-1.5 px-3 py-1.5 bg-amber-50 text-amber-700 rounded-token-xl font-bold border-2 border-amber-100 hover:bg-amber-100 transition-all shadow-sm shadow-amber-500/5"
          title="Reconnect integration"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Reconnect
        </button>
      </:header_action>

      <:detail>
        <div :if={@integration.is_active}>
          <div class="flex items-center gap-2 mb-3">
            <span class="text-token-2xs font-black uppercase tracking-widest text-tymeslot-400">
              Syncing {Enum.count(@calendar_list, &(&1["selected"] || &1[:selected]))} Calendars
            </span>
            <div class="h-px bg-tymeslot-100 flex-1"></div>
          </div>

          <div class="flex flex-wrap gap-2.5">
            <%= for calendar <- @calendar_list do %>
              <% calendar_id = calendar["id"] || calendar[:id] %>
              <% calendar_name = DisplayHelpers.extract_calendar_display_name(calendar) %>
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

            <div :if={@calendar_list == []} class="flex items-center gap-2 text-tymeslot-400 py-2">
              <svg
                class="w-4 h-4 animate-pulse"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
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
      </:detail>

      <:actions>
        <button
          :if={@integration.provider == "google" && Helpers.needs_scope_upgrade?(@integration)}
          phx-click="upgrade_google_scope"
          phx-value-id={@integration.id}
          phx-target={@myself}
          class="flex items-center gap-2 px-4 py-2 bg-amber-50 text-amber-700 rounded-token-xl font-bold border-2 border-amber-100 hover:bg-amber-100 transition-all shadow-sm shadow-amber-500/5"
          title="Upgrade Google Calendar permissions"
        >
          <.icon name="hero-bolt" class="w-4 h-4" /> Upgrade
        </button>
        <button
          :if={@integration.provider in ["google", "outlook"] && !@integration.needs_reauth}
          phx-click="connect_provider"
          phx-value-provider={@integration.provider}
          phx-target={@myself}
          class="flex items-center gap-2 px-4 py-2 bg-tymeslot-50 text-tymeslot-700 rounded-token-xl font-bold border-2 border-tymeslot-100 hover:bg-tymeslot-100 transition-all shadow-sm shadow-tymeslot-500/5"
          title="Reconnect integration"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Reconnect
        </button>
        <button
          :if={@integration.provider not in ["google", "outlook"] && !@integration.needs_reauth}
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
          class="ml-auto flex items-center gap-2 px-4 py-2 text-tymeslot-500 hover:text-red-500 hover:bg-red-50 rounded-token-xl font-bold border-2 border-transparent hover:border-red-100 transition-all"
          title="Remove Connection"
        >
          <.icon name="hero-trash" class="w-4 h-4" /> Delete
        </button>
      </:actions>
    </ConnectionRow.connection_row>
    """
  end

  @doc """
  Builds a one-line human summary for a calendar integration — account
  email, conflict-check coverage, booking target, and last-sync — dropping
  absent segments gracefully.
  """
  @spec calendar_summary(map()) :: String.t()
  def calendar_summary(integration) do
    calendar_list = integration.calendar_list || []

    [
      integration.provider_account_email,
      conflict_segment(integration, calendar_list),
      booking_segment(integration, calendar_list),
      sync_segment(integration)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # Status-first badge mapping, dispatched on integration/health shape.
  defp integration_status(%{is_active: false}, _health), do: {:paused, "Paused"}
  defp integration_status(%{needs_reauth: true}, _health), do: {:warning, "Reconnect"}

  defp integration_status(_integration, %{status: :unhealthy}),
    do: {:warning, "Connection issues"}

  defp integration_status(_integration, _health), do: {:ok, "Healthy"}

  defp conflict_segment(%{is_active: true}, calendar_list) when calendar_list != [] do
    selected = Enum.count(calendar_list, &(&1["selected"] || &1[:selected]))
    "conflict-checks #{selected} of #{length(calendar_list)} calendars"
  end

  defp conflict_segment(_integration, _calendar_list), do: nil

  defp booking_segment(integration, calendar_list) do
    case booking_calendar(integration, calendar_list) do
      nil -> nil
      calendar -> "books into #{DisplayHelpers.extract_calendar_display_name(calendar)}"
    end
  end

  defp booking_calendar(integration, calendar_list) do
    booking_id = Map.get(integration, :default_booking_calendar_id)

    Enum.find(calendar_list, &(booking_id && (&1["id"] || &1[:id]) == booking_id)) ||
      Enum.find(calendar_list, &(&1["primary"] || &1[:primary]))
  end

  defp sync_segment(%{last_sync_at: %DateTime{} = synced_at}),
    do: "synced #{TokenUtils.relative_time(synced_at)}"

  defp sync_segment(_integration), do: nil

  defp row_expanded?(nil, _id), do: false
  defp row_expanded?(set, id), do: MapSet.member?(set, to_string(id))

  defp format_provider_title(:nextcloud), do: "Nextcloud"
  defp format_provider_title(:radicale), do: "Radicale"
  defp format_provider_title(:caldav), do: "CalDAV"
  defp format_provider_title(:zimbra), do: "Zimbra"
  defp format_provider_title(:mailbox_org), do: "mailbox.org"
  defp format_provider_title(:apple), do: "Apple iCloud"
  defp format_provider_title(:baikal), do: "Baikal"
  defp format_provider_title(_provider), do: "Calendar"
end
