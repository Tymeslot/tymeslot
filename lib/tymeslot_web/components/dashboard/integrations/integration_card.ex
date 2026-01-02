defmodule TymeslotWeb.Components.Dashboard.Integrations.IntegrationCard do
  @moduledoc """
  Reusable integration card component for dashboard integration displays.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Components.Icons.ProviderIcon
  alias TymeslotWeb.Components.UI.StatusSwitch

  @spec integration_card(map()) :: Phoenix.LiveView.Rendered.t()
  def integration_card(assigns) do
    # Ensure checking_connection is available with a default value
    assigns = Map.put_new(assigns, :checking_connection, nil)

    ~H"""
    <div class={[
      "card-glass flex flex-col relative pb-10",
      if(@integration.is_active, do: "card-glass-available", else: "card-glass-unavailable"),
      if(@integration_type == :calendar,
        do:
          if(Map.get(@integration, :is_primary, false),
            do: "card-glass-primary",
            else: "card-glass-calendar-secondary"
          ),
        else: ""
      )
    ]}>
      <div class="integration-header">
        <div class="integration-info">
          <ProviderIcon.provider_icon provider={@integration.provider} size="compact" />
          <div class="integration-details">
            <div class="integration-title-row">
              <h3 class="integration-name">
                {@integration.name}
                <%= if Map.has_key?(@integration, :is_default) and @integration.is_default do %>
                  <svg
                    class="w-4 h-4 ml-2 text-yellow-500 inline"
                    fill="currentColor"
                    viewBox="0 0 20 20"
                  >
                    <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.197-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z" />
                  </svg>
                <% end %>
              </h3>
              <%= if @integration.is_active do %>
                <span class="status-badge status-badge--active">Active</span>
              <% else %>
                <span class="status-badge status-badge--inactive">Inactive</span>
              <% end %>
            </div>
            <p class="integration-provider">
              <%= if @integration.provider in ["nextcloud", "caldav"] and @integration.base_url do %>
                {URI.parse(@integration.base_url).host}
              <% else %>
                {@provider_display_name}
                <%= if @integration.provider in ["mirotalk", "custom"] and @integration.base_url do %>
                  • {URI.parse(@integration.base_url).host}
                <% end %>
                <%= if Map.has_key?(@integration, :custom_meeting_url) and @integration.custom_meeting_url do %>
                  • Custom URL
                <% end %>
              <% end %>
            </p>
          </div>
        </div>
        
    <!-- Status Toggle -->
        <StatusSwitch.status_switch
          id={"integration-toggle-#{@integration.id}"}
          checked={@integration.is_active}
          on_change="toggle_integration"
          target={@myself}
          phx_value_id={to_string(@integration.id)}
          size={:large}
          class="ring-2 ring-turquoise-300/50"
        />
      </div>
      
    <!-- Integration Details -->
      <div class="integration-content flex-1 flex flex-col">
        <%= if @integration_type == :calendar do %>
          <div class="calendar-details">
            <%= if Map.get(@integration, :is_primary, false) do %>
              <div class="mb-3 p-3 bg-turquoise-50 border border-turquoise-200 rounded-lg">
                <div class="text-sm font-semibold text-turquoise-800 mb-1">
                  <svg
                    class="w-4 h-4 mr-2 inline text-turquoise-600"
                    fill="currentColor"
                    viewBox="0 0 20 20"
                  >
                    <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.197-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z" />
                  </svg>
                  📝 Booking Calendar
                </div>
                <p class="text-xs text-turquoise-700 mb-2">
                  New appointments from Tymeslot will be saved here
                </p>
                <%= if @integration.default_booking_calendar_id do %>
                  <p class="text-xs text-turquoise-600">
                    Target → <strong>{get_booking_calendar_name(@integration)}</strong>
                  </p>
                <% end %>
              </div>
            <% else %>
              <div class="mb-3 p-3 bg-blue-50 border border-blue-200 rounded-lg">
                <div class="text-sm font-semibold text-blue-800 mb-1">
                  <svg
                    class="w-4 h-4 mr-2 inline text-blue-600"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  👁️ Sync-Only Calendar
                </div>
                <p class="text-xs text-blue-700">
                  Prevents double-bookings by checking this calendar for conflicts
                </p>
              </div>
            <% end %>

            <%= if @integration.calendar_list && length(@integration.calendar_list) > 0 do %>
              <div class="calendar-summary">
                <span class="text-sm text-gray-600">
                  Syncing {Enum.count(@integration.calendar_list, &(&1["selected"] || &1[:selected]))} calendars
                </span>
              </div>
            <% else %>
              <%= if length(@integration.calendar_paths || []) > 0 do %>
                <div class="calendar-summary">
                  <span class="text-sm text-gray-600">
                    Connected to {length(@integration.calendar_paths)} calendars
                  </span>
                </div>
              <% else %>
                <p class="calendar-details-empty">No specific calendars configured</p>
              <% end %>
            <% end %>

            <%= if !@integration.is_active do %>
              <p class="integration-disabled-note">
                Integration is currently disabled. Enable to start syncing calendar events.
              </p>
            <% end %>
          </div>
        <% else %>
          <!-- Video Integration Details -->
          <%= if @integration.is_active do %>
            <div class="mb-4">
              <p class="text-sm text-gray-600 font-medium mb-2">Configuration:</p>
              <div class="space-y-1">
                <%= if @integration.provider == "google_meet" do %>
                  <div class="flex items-center text-xs text-gray-500">
                    <svg class="w-3 h-3 mr-1 text-green-500" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                        clip-rule="evenodd"
                      />
                    </svg>
                    OAuth authenticated
                  </div>
                <% end %>
                <%= if @integration.provider == "teams" do %>
                  <div class="flex items-center text-xs text-gray-500">
                    <svg class="w-3 h-3 mr-1 text-green-500" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                        clip-rule="evenodd"
                      />
                    </svg>
                    Teams authenticated
                  </div>
                <% end %>
                <%= if @integration.base_url do %>
                  <div class="flex items-center text-xs text-gray-500">
                    <svg
                      class="w-3 h-3 mr-1 text-blue-500"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
                      />
                    </svg>
                    Base URL configured
                  </div>
                <% end %>
                <%= if Map.has_key?(@integration, :custom_meeting_url) and @integration.custom_meeting_url do %>
                  <div class="flex items-center text-xs text-gray-500">
                    <svg
                      class="w-3 h-3 mr-1 text-purple-500"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
                      />
                    </svg>
                    Custom URL set
                  </div>
                <% end %>
                <%= if @integration.provider == "none" do %>
                  <div class="flex items-center text-xs text-gray-500">
                    <svg
                      class="w-3 h-3 mr-1 text-amber-500"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"
                      />
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"
                      />
                    </svg>
                    Location-based meetings
                  </div>
                <% end %>
              </div>
            </div>
          <% else %>
            <div class="mb-4">
              <p class="text-sm text-gray-500 italic">Integration is currently disabled</p>
              <p class="text-xs text-gray-400 mt-1">
                Enable to start using this {@integration_type} provider
              </p>
            </div>
          <% end %>
        <% end %>
        
    <!-- Action Buttons -->
        <div class="integration-actions mt-auto">
          <%= if @integration_type == :calendar do %>
            <%= if @integration.is_active do %>
              <button
                phx-click="manage_calendars"
                phx-value-id={@integration.id}
                phx-target={@myself}
                class="btn btn-sm btn-primary"
                style="position: absolute; bottom: 1rem; right: 1rem; z-index: 10;"
                title="Manage Integration"
                disabled={@checking_connection == @integration.id}
              >
                <%= if @checking_connection == @integration.id do %>
                  <div class="absolute inset-0 flex items-center justify-center bg-turquoise-600/90 rounded">
                    <div class="flex items-center">
                      <svg
                        class="animate-spin h-4 w-4 mr-2 text-white"
                        xmlns="http://www.w3.org/2000/svg"
                        fill="none"
                        viewBox="0 0 24 24"
                      >
                        <circle
                          class="opacity-25"
                          cx="12"
                          cy="12"
                          r="10"
                          stroke="currentColor"
                          stroke-width="4"
                        >
                        </circle>
                        <path
                          class="opacity-75"
                          fill="currentColor"
                          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                        >
                        </path>
                      </svg>
                      <span class="text-white text-sm">Connecting...</span>
                    </div>
                  </div>
                <% end %>
                <div class={
                  if @checking_connection == @integration.id,
                    do: "opacity-0",
                    else: "flex items-center justify-center"
                }>
                  <svg class="action-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
                    />
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                    />
                  </svg>
                  <span>Manage</span>
                </div>
              </button>
            <% end %>
          <% else %>
            <!-- Video Integration Actions -->
            <%= if @integration.is_active do %>
              <button
                phx-click="test_connection"
                phx-value-id={@integration.id}
                phx-target={@myself}
                disabled={@testing_connection == @integration.id}
                class="btn btn-sm btn-secondary min-w-[80px]"
                style="position: absolute; bottom: 1rem; right: 1rem; z-index: 10;"
                title="Test Connection"
              >
                <%= if @testing_connection == @integration.id do %>
                  <svg class="animate-spin h-3 w-3 mr-1" fill="none" viewBox="0 0 24 24">
                    <circle
                      class="opacity-25"
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      stroke-width="4"
                    >
                    </circle>
                    <path
                      class="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                    >
                    </path>
                  </svg>
                  Testing...
                <% else %>
                  <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  Test
                <% end %>
              </button>

              <%= if Map.has_key?(@integration, :is_default) and !@integration.is_default do %>
                <button
                  phx-click="set_default"
                  phx-value-id={@integration.id}
                  phx-target={@myself}
                  class="btn btn-sm bg-green-600 hover:bg-green-700 text-white min-w-[90px]"
                >
                  <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M11.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.197-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z"
                    />
                  </svg>
                  Set Default
                </button>
              <% end %>
              
    <!-- Delete button removed in favor of persistent trash icon in card corner -->
            <% else %>
              <button
                phx-click="toggle_integration"
                phx-value-id={@integration.id}
                phx-target={@myself}
                class="btn btn-sm btn-primary min-w-[90px]"
              >
                <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M4.5 12.75l6 6 9-13.5"
                  />
                </svg>
                Enable
              </button>
            <% end %>
          <% end %>
        </div>
        <!-- Persistent trash icon in bottom-left corner -->
        <button
          phx-click="show_delete_modal"
          phx-value-id={@integration.id}
          phx-target={@myself}
          class="text-gray-500 hover:text-red-600"
          style="position: absolute; bottom: 1rem; left: 1rem; z-index: 10;"
          title="Delete Integration"
          aria-label="Delete Integration"
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
      </div>
    </div>
    """
  end

  defp get_booking_calendar_name(integration) do
    if integration.default_booking_calendar_id && integration.calendar_list do
      calendar =
        Enum.find(integration.calendar_list, fn cal ->
          (cal["id"] || cal[:id]) == integration.default_booking_calendar_id
        end)

      if calendar do
        calendar["name"] || calendar[:name] || "Calendar"
      else
        "Primary Calendar"
      end
    else
      "Primary Calendar"
    end
  end
end
