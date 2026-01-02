defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.CalendarManagerModal do
  @moduledoc """
  Modal component for managing calendar integrations.
  Handles calendar selection, primary integration settings, and deletion.
  """
  use TymeslotWeb, :live_component

  alias Phoenix.LiveView
  alias Tymeslot.Integrations.Calendar

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:loading_calendars, false)
     |> assign(:managing_integration, nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("update_calendar_selection", %{"calendars" => params}, socket) do
    # Update the calendar selection state in real-time for UI reactivity
    integration = socket.assigns.managing_integration
    selected_calendar_ids = params["selected_calendars"] || []

    # Update calendar_list with new selection state
    updated_calendar_list =
      Enum.map(integration.calendar_list || [], fn calendar ->
        calendar_id = calendar["id"] || calendar[:id]
        updated_selected = calendar_id in selected_calendar_ids

        calendar
        |> Map.put("selected", updated_selected)
        # Support both string and atom keys
        |> Map.put(:selected, updated_selected)
      end)

    updated_integration = %{integration | calendar_list: updated_calendar_list}

    {:noreply, assign(socket, :managing_integration, updated_integration)}
  end

  def handle_event("save_calendar_selection", %{"calendars" => form_params} = _params, socket) do
    # Build selection payload from current modal state and forward to parent component
    integration = socket.assigns.managing_integration

    selected_ids =
      (integration.calendar_list || [])
      |> Enum.filter(fn cal -> cal["selected"] || cal[:selected] end)
      |> Enum.map(fn cal -> cal["id"] || cal[:id] end)

    # Merge computed selections into the inner calendars form params
    calendars_params = Map.put(form_params, "selected_calendars", selected_ids)

    LiveView.send_update(
      TymeslotWeb.Dashboard.CalendarSettingsComponent,
      id: "calendar",
      event: "save_calendar_selection",
      params: %{"calendars" => calendars_params}
    )

    {:noreply, socket}
  end

  def handle_event("upgrade_google_scope", _params, socket) do
    send(self(), {:upgrade_google_scope, socket.assigns.managing_integration.id})
    {:noreply, socket}
  end

  # hide handled by parent via events; this local handler is no longer used

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal
        id="calendar-manager-modal"
        show={@show}
        on_cancel={JS.push("hide_calendar_manager", target: @parent)}
        size={:large}
      >
        <:header>
          <div class="flex items-center justify-between w-full">
            <div class="flex items-center">
              <span>Manage Integration</span>
              <%= if @managing_integration do %>
                <span class="text-gray-500 ml-2">
                  - {format_provider_name(@managing_integration.provider)}
                </span>
                <%= if Map.get(@managing_integration, :is_primary, false) do %>
                  <span class="inline-flex items-center ml-3 px-2 py-1 text-xs font-medium bg-turquoise-100 text-turquoise-800 rounded-full">
                    📝 Booking Calendar
                  </span>
                <% end %>
              <% end %>
            </div>
            <%= if @managing_integration && @managing_integration.is_active do %>
              <div class="flex items-center gap-2">
                <%= if not Map.get(@managing_integration, :is_primary, false) do %>
                  <button
                    phx-click="set_as_primary"
                    phx-target={@parent}
                    phx-value-id={@managing_integration.id}
                    class="btn btn-xs bg-green-600 hover:bg-green-700 text-white"
                    title="Use for Creating Bookings"
                  >
                    <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M11.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.197-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z"
                      />
                    </svg>
                    Use for Bookings
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>
        </:header>

        <%= if @managing_integration do %>
          <%= if @loading_calendars do %>
            <div class="text-center py-8 max-w-md mx-auto">
              <div class="inline-flex items-center">
                <.spinner />
                <span class="ml-3">Discovering calendars...</span>
              </div>
            </div>
          <% else %>
            <form
              id="calendar-selection-form"
              phx-submit="save_calendar_selection"
              phx-change="update_calendar_selection"
              phx-target={@myself}
              class="max-w-md mx-auto"
            >
              <!-- Calendar Selection -->
              <div class="mb-6">
                <h4 class="text-sm font-medium mb-3">Select calendars to sync:</h4>
                <div class="space-y-2 max-h-60 overflow-y-auto card-glass p-2">
                  <%= for calendar <- @managing_integration.calendar_list || [] do %>
                    <label class="flex items-center p-3 rounded-lg hover:bg-white/50 cursor-pointer transition-colors">
                      <input
                        type="checkbox"
                        name="calendars[selected_calendars][]"
                        value={calendar["id"] || calendar[:id]}
                        checked={calendar["selected"] || calendar[:selected]}
                        class="h-4 w-4 text-turquoise-600 focus:ring-turquoise-500 border-gray-300 rounded"
                      />
                      <div class="ml-3 flex-1">
                        <span class="text-sm font-medium">
                          {calendar["name"] || calendar[:name] || "Calendar"}
                        </span>
                        <%= if calendar["primary"] || calendar[:primary] do %>
                          <span class="ml-2 text-xs opacity-70">(Primary)</span>
                        <% end %>
                        <%= if calendar["owner"] || calendar[:owner] do %>
                          <span class="ml-2 text-xs opacity-70">
                            Owner: {calendar["owner"] || calendar[:owner]}
                          </span>
                        <% end %>
                      </div>
                      <%= if calendar["color"] || calendar[:color] do %>
                        <div
                          class="w-4 h-4 rounded-full ml-2 border border-white/20"
                          style={"background-color: #{calendar["color"] || calendar[:color]}"}
                        >
                        </div>
                      <% end %>
                    </label>
                  <% end %>
                </div>
              </div>
              
    <!-- Booking Calendar Selection - Only for Primary Integration -->
              <%= if Map.get(@managing_integration, :is_primary, false) do %>
                <div class="mb-6">
                  <h4 class="text-sm font-medium mb-3">
                    Where should new bookings be created?
                  </h4>
                  <select
                    name="calendars[default_booking_calendar]"
                    required
                    class="mt-1 block w-full glass-dropdown"
                  >
                    <option value="">Select a calendar...</option>
                    <%= for calendar <- @managing_integration.calendar_list || [], 
                    calendar["selected"] || calendar[:selected] do %>
                      <option
                        value={calendar["id"] || calendar[:id]}
                        selected={
                          (calendar["id"] || calendar[:id]) ==
                            @managing_integration.default_booking_calendar_id
                        }
                      >
                        {calendar["name"] || calendar[:name] || "Calendar"}
                        <%= if calendar["primary"] || calendar[:primary] do %>
                          (Primary)
                        <% end %>
                      </option>
                    <% end %>
                  </select>
                  <p class="mt-2 text-sm opacity-70">
                    New meetings will be created in this calendar. You can change this anytime.
                  </p>
                </div>
              <% else %>
                <div class="mb-6 p-4 bg-blue-50 border border-blue-200 rounded-lg">
                  <div class="flex items-start">
                    <svg
                      class="w-5 h-5 text-blue-400 mt-0.5 mr-3"
                      fill="currentColor"
                      viewBox="0 0 20 20"
                    >
                      <path
                        fill-rule="evenodd"
                        d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
                        clip-rule="evenodd"
                      />
                    </svg>
                    <div>
                      <h4 class="text-sm font-medium text-blue-800">👁️ Sync-Only Calendar</h4>
                      <p class="text-sm text-blue-600 mt-1">
                        This calendar checks for conflicts but doesn't receive new bookings.
                        To create bookings here, click "Use for Bookings" above.
                      </p>
                    </div>
                  </div>
                </div>
              <% end %>
            </form>
          <% end %>
        <% end %>

        <:footer>
          <%= if @managing_integration && !@loading_calendars do %>
            <div class="flex items-center justify-between w-full">
              <div class="flex items-center gap-3">
                <%= if @managing_integration.provider == "google" and needs_scope_upgrade?(@managing_integration) do %>
                  <button
                    type="button"
                    phx-click="upgrade_google_scope"
                    phx-target={@parent}
                    class="btn btn-sm btn-warning"
                  >
                    <svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M13 10V3L4 14h7v7l9-11h-7z"
                      />
                    </svg>
                    Upgrade Google Scope
                  </button>
                <% end %>
              </div>
              <div class="flex gap-3">
                <.action_button
                  variant={:secondary}
                  phx-click="hide_calendar_manager"
                  phx-target={@parent}
                >
                  Cancel
                </.action_button>
                <button
                  type="submit"
                  form="calendar-selection-form"
                  class="action-button action-button--primary"
                  disabled={@loading_calendars}
                >
                  Save Changes
                </button>
              </div>
            </div>
          <% else %>
            <div class="flex items-center justify-end w-full">
              <.action_button
                variant={:secondary}
                phx-click="hide_calendar_manager"
                phx-target={@parent}
              >
                Close
              </.action_button>
            </div>
          <% end %>
        </:footer>
      </.modal>
    </div>
    """
  end

  defp format_provider_name(provider) do
    case provider do
      "google" -> "Google Calendar"
      "outlook" -> "Outlook Calendar"
      "nextcloud" -> "Nextcloud"
      "caldav" -> "CalDAV"
      _ -> String.capitalize(provider)
    end
  end

  defp needs_scope_upgrade?(integration) do
    Calendar.needs_scope_upgrade?(integration)
  end
end
