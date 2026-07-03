defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavReconnectModal do
  @moduledoc """
  Modal for reconnecting an existing CalDAV-family calendar integration.
  See `Tymeslot.Integrations.Calendar.Reconnection`.

  The modal owns its own state: open/closed, phase, form values, the
  discovery payload, and the submission flag. The parent
  `CalendarSettingsComponent` opens it by pushing the integration to
  reconnect via `send_update/2`:

      send_update(CaldavReconnectModal,
        id: "caldav-reconnect-modal",
        integration_to_reconnect: integration
      )

  Two phases:
  - `:credentials` — user enters URL, username, and password.
  - `:calendar_selection` — user confirms which calendars to sync.
    Previously selected calendars are pre-ticked.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Utils.ChangesetUtils
  alias TymeslotWeb.Components.CoreComponents

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Dashboard.CalendarSettingsComponent
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @parent_component_id "calendar-settings"

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, reset_state(socket)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl Phoenix.LiveComponent
  def handle_event("show_reconnect", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with {:ok, int_id} <- parse_int(id),
         {:ok, integration} <- Calendar.get_integration(int_id, user_id) do
      {:noreply, open_with_integration(socket, integration)}
    else
      :error ->
        Flash.error("Invalid calendar ID")
        {:noreply, socket}

      {:error, :not_found} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  def handle_event("close_reconnect_modal", _params, socket) do
    {:noreply, reset_state(socket)}
  end

  def handle_event("reconnect_caldav_discover", %{"reconnect" => params}, socket) do
    integration = socket.assigns.integration
    user_id = socket.assigns.current_user.id
    socket = assign(socket, :is_submitting, true)

    case Calendar.reconnect_caldav_integration(user_id, integration.id, params) do
      {:ok, :needs_calendar_selection, payload} ->
        selected_paths = Enum.filter(integration.calendar_paths || [], &is_binary/1)

        {:noreply,
         socket
         |> assign(:phase, :calendar_selection)
         |> assign(:discovery_payload, payload)
         |> assign(:selected_paths, selected_paths)
         |> assign(:form_errors, %{})
         |> assign(:is_submitting, false)}

      {:error, :invalid_credentials} ->
        {:noreply,
         socket
         |> assign(:form_errors, %{generic: ["Could not sign in with those credentials"]})
         |> assign(:form_values, params)
         |> assign(:is_submitting, false)}

      {:error, :not_found} ->
        Flash.error("Integration not found")
        {:noreply, reset_state(socket)}

      {:error, reason} when is_binary(reason) ->
        {:noreply,
         socket
         |> assign(:form_errors, %{generic: [reason]})
         |> assign(:form_values, params)
         |> assign(:is_submitting, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form_errors, %{generic: [DisplayHelpers.connection_error_message(reason)]})
         |> assign(:form_values, params)
         |> assign(:is_submitting, false)}
    end
  end

  def handle_event("reconnect_caldav_submit", _params, socket)
      when is_nil(socket.assigns.discovery_payload) do
    Flash.error("Session expired. Please start the reconnect process again.")
    {:noreply, reset_state(socket)}
  end

  def handle_event("reconnect_caldav_submit", params, socket) do
    integration = socket.assigns.integration
    user_id = socket.assigns.current_user.id
    payload = socket.assigns.discovery_payload
    selected_paths = params |> Map.get("selected_paths", []) |> List.wrap()
    socket = assign(socket, :is_submitting, true)

    case Calendar.finalise_caldav_reconnect(user_id, integration.id, %{
           payload: payload,
           selected_paths: selected_paths
         }) do
      {:ok, _updated} ->
        send(self(), {:integration_updated, :calendar})
        send_update(CalendarSettingsComponent, id: @parent_component_id)
        Flash.info("Calendar reconnected")
        {:noreply, reset_state(socket)}

      {:error, :no_calendars_selected} ->
        {:noreply,
         socket
         |> assign(:form_errors, %{generic: ["Please select at least one calendar to sync."]})
         |> assign(:is_submitting, false)}

      {:error, :not_found} ->
        Flash.error("Integration not found")
        {:noreply, reset_state(socket)}

      {:error, {:changeset, cs}} ->
        Flash.error("Could not save: #{ChangesetUtils.get_first_error(cs)}")
        {:noreply, assign(socket, :is_submitting, false)}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <CoreComponents.modal
        :if={@show}
        id={"#{@id}-modal"}
        show={true}
        on_cancel={JS.push("close_reconnect_modal", target: @myself)}
        size={:medium}
      >
        <:header>Reconnect {@integration.name}</:header>

        <%= case @phase do %>
          <% :credentials -> %>
            <.credentials_form
              form_values={@form_values}
              form_errors={@form_errors}
              is_submitting={@is_submitting}
              target={@myself}
              locked_url={@locked_url}
            />
          <% :calendar_selection -> %>
            <.calendar_selection
              payload={@discovery_payload}
              selected_paths={@selected_paths}
              form_errors={@form_errors}
              is_submitting={@is_submitting}
              target={@myself}
            />
        <% end %>
      </CoreComponents.modal>
    </div>
    """
  end

  attr :form_values, :map, required: true
  attr :form_errors, :map, required: true
  attr :is_submitting, :boolean, required: true
  attr :target, :any, required: true
  attr :locked_url, :map, default: nil

  defp credentials_form(assigns) do
    ~H"""
    <form id="caldav-reconnect-credentials-form" phx-submit="reconnect_caldav_discover" phx-target={@target} class="space-y-5">
      <p class="text-sm text-tymeslot-500">
        Confirm or update the server URL and credentials for this integration.
        You'll be able to review and adjust the synced calendars on the next step.
      </p>

      <%= if @locked_url do %>
        <SharedForm.locked_url_field
          value={@locked_url.url}
          tooltip={@locked_url.tooltip}
          name="reconnect[url]"
        />
      <% else %>
        <.input
          id="reconnect_url"
          name="reconnect[url]"
          type="url"
          label="Server URL"
          value={@form_values["url"]}
          required
          icon="hero-globe-alt"
          errors={FormValidationHelpers.field_errors(@form_errors, :url)}
        />
      <% end %>

      <.input
        id="reconnect_username"
        name="reconnect[username]"
        type="text"
        label="Username"
        value={@form_values["username"]}
        required
        icon="hero-user"
        errors={FormValidationHelpers.field_errors(@form_errors, :username)}
      />

      <.input
        id="reconnect_password"
        name="reconnect[password]"
        type="password"
        label="Password / App Password"
        value={@form_values["password"]}
        required
        icon="hero-lock-closed"
        errors={FormValidationHelpers.field_errors(@form_errors, :password)}
      />

      <%= if error = form_level_error(@form_errors) do %>
        <div class="brand-card p-3 bg-red-50/50 border border-red-200/50">
          <p class="text-sm text-red-600 flex items-center">
            <.icon name="hero-exclamation-circle-solid" class="w-4 h-4 mr-2 shrink-0" />
            {error}
          </p>
        </div>
      <% end %>

      <div class="flex justify-end gap-3 pt-4 border-t border-turquoise-200/30">
        <CoreComponents.action_button
          variant={:secondary}
          phx-click={JS.push("close_reconnect_modal", target: @target)}
        >
          Cancel
        </CoreComponents.action_button>
        <CoreComponents.loading_button
          variant={:primary}
          type="submit"
          loading={@is_submitting}
          loading_text="Testing..."
        >
          Reconnect
        </CoreComponents.loading_button>
      </div>
    </form>
    """
  end

  attr :payload, :map, required: true
  attr :selected_paths, :list, required: true
  attr :form_errors, :map, required: true
  attr :is_submitting, :boolean, required: true
  attr :target, :any, required: true

  defp calendar_selection(assigns) do
    ~H"""
    <form id="caldav-reconnect-calendars-form" phx-submit="reconnect_caldav_submit" phx-target={@target} class="space-y-5">
      <p class="text-sm text-tymeslot-500">
        Select the calendars you want to sync for availability checks.
        Calendars you previously synced are already ticked — untick to stop
        syncing them, or tick new calendars to add them.
      </p>

      <%= if error = form_level_error(@form_errors) do %>
        <div class="brand-card p-3 bg-red-50/50 border border-red-200/50">
          <p class="text-sm text-red-600 flex items-center">
            <.icon name="hero-exclamation-circle-solid" class="w-4 h-4 mr-2 shrink-0" />
            {error}
          </p>
        </div>
      <% end %>

      <div class="space-y-3">
        <h4 class="label">Select calendars to sync:</h4>
        <div class="brand-card p-4">
          <%= if @payload.calendars == [] do %>
            <p class="text-sm text-tymeslot-500">
              No calendars were discovered. Double-check your credentials or try again.
            </p>
          <% else %>
            <%= for calendar <- @payload.calendars do %>
              <% path = calendar[:path] || calendar["path"] || calendar[:href] %>
              <% name = calendar[:name] || calendar["name"] || path %>
              <div class="flex items-center space-x-3 p-3 rounded-lg hover:bg-white/20 transition-colors">
                <.input
                  type="checkbox"
                  name="selected_paths[]"
                  value={path}
                  checked={path in @selected_paths}
                  id={"reconnect-calendar-#{String.replace(path, "/", "-")}"}
                />
                <label
                  for={"reconnect-calendar-#{String.replace(path, "/", "-")}"}
                  class="flex-1 cursor-pointer"
                >
                  <div class="font-semibold text-tymeslot-800">{name}</div>
                  <div class="text-sm text-tymeslot-600">{path}</div>
                </label>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>

      <div class="flex justify-end gap-3 pt-4 border-t border-turquoise-200/30">
        <CoreComponents.action_button
          variant={:secondary}
          phx-click={JS.push("close_reconnect_modal", target: @target)}
        >
          Cancel
        </CoreComponents.action_button>
        <CoreComponents.loading_button
          variant={:primary}
          type="submit"
          loading={@is_submitting}
          loading_text="Saving..."
        >
          Save selection
        </CoreComponents.loading_button>
      </div>
    </form>
    """
  end

  defp open_with_integration(socket, integration) do
    socket
    |> assign(:show, true)
    |> assign(:integration, integration)
    |> assign(:locked_url, ProviderConfig.locked_url_for(integration.provider))
    |> assign(:phase, :credentials)
    |> assign(:form_errors, %{})
    |> assign(:form_values, %{
      "url" => integration.base_url || "",
      "username" => integration.username || "",
      "password" => ""
    })
    |> assign(:discovery_payload, nil)
    |> assign(:selected_paths, [])
    |> assign(:is_submitting, false)
  end

  defp reset_state(socket) do
    socket
    |> assign(:show, false)
    |> assign(:integration, nil)
    |> assign(:locked_url, nil)
    |> assign(:phase, :credentials)
    |> assign(:form_values, %{})
    |> assign(:form_errors, %{})
    |> assign(:discovery_payload, nil)
    |> assign(:selected_paths, [])
    |> assign(:is_submitting, false)
  end

  defp parse_int(id) when is_integer(id), do: {:ok, id}

  defp parse_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _other -> :error
    end
  end

  defp parse_int(_arg), do: :error

  defp form_level_error(form_errors) do
    [
      Map.get(form_errors, :discovery),
      Map.get(form_errors, :base),
      Map.get(form_errors, :generic)
    ]
    |> Enum.find(& &1)
    |> normalize_error_message()
  end

  defp normalize_error_message(nil), do: nil
  defp normalize_error_message([message | _rest]) when is_binary(message), do: message
  defp normalize_error_message(message) when is_binary(message), do: message
  defp normalize_error_message(_other), do: "Something went wrong. Please try again."
end
