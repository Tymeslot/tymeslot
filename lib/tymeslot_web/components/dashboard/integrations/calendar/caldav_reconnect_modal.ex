defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavReconnectModal do
  @moduledoc """
  Modal for reconnecting an existing CalDAV-family calendar integration.
  See `Tymeslot.Integrations.Calendar.Reconnection` for the underlying
  branching rules.

  Two phases:

  - `:credentials` — user enters new URL, username, and password. The
    parent LiveView handles `reconnect_caldav_discover` on submit.
  - `:calendar_selection` — shown only when the new credentials point at a
    different account than the stored ones. User picks which calendars to
    sync. The parent LiveView handles `reconnect_caldav_submit` on submit.

  The component is a thin presentation wrapper: every event targets
  `@parent_target` (`@myself` of the parent LiveView or LiveComponent).
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def update(%{integration: integration} = assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:phase, fn -> :credentials end)
      |> assign_new(:form_errors, fn -> %{} end)
      |> assign_new(:form_values, fn ->
        %{
          "url" => integration.base_url || "",
          "username" => integration.username || "",
          "password" => ""
        }
      end)
      |> assign_new(:discovery_payload, fn -> nil end)
      |> assign_new(:selected_paths, fn -> [] end)
      |> assign_new(:is_submitting, fn -> false end)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <CoreComponents.modal
        id={"#{@id}-modal"}
        show={true}
        on_cancel={JS.push("close_reconnect_modal", target: @parent_target)}
        size={:medium}
      >
        <:header>Reconnect {@integration.name}</:header>

        <%= case @phase do %>
          <% :credentials -> %>
            <.credentials_form
              form_values={@form_values}
              form_errors={@form_errors}
              is_submitting={@is_submitting}
              parent_target={@parent_target}
            />
          <% :calendar_selection -> %>
            <.calendar_selection
              payload={@discovery_payload}
              selected_paths={@selected_paths}
              form_errors={@form_errors}
              is_submitting={@is_submitting}
              parent_target={@parent_target}
            />
        <% end %>
      </CoreComponents.modal>
    </div>
    """
  end

  attr :form_values, :map, required: true
  attr :form_errors, :map, required: true
  attr :is_submitting, :boolean, required: true
  attr :parent_target, :any, required: true

  defp credentials_form(assigns) do
    ~H"""
    <form phx-submit="reconnect_caldav_discover" phx-target={@parent_target} class="space-y-5">
      <p class="text-sm text-tymeslot-500">
        Update the server URL and credentials for this integration. Existing
        calendar selections are preserved when only the password changes.
      </p>

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
            <.icon name="hero-exclamation-circle-solid" class="w-4 h-4 mr-2 flex-shrink-0" />
            {error}
          </p>
        </div>
      <% end %>

      <div class="flex justify-end gap-3 pt-4 border-t border-turquoise-200/30">
        <CoreComponents.action_button
          variant={:secondary}
          phx-click={JS.push("close_reconnect_modal", target: @parent_target)}
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
  attr :parent_target, :any, required: true

  defp calendar_selection(assigns) do
    ~H"""
    <form phx-submit="reconnect_caldav_submit" phx-target={@parent_target} class="space-y-5">
      <p class="text-sm text-tymeslot-500">
        The new credentials belong to a different account. Select the calendars
        you want to sync for availability checks.
      </p>

      <%= if error = form_level_error(@form_errors) do %>
        <div class="brand-card p-3 bg-red-50/50 border border-red-200/50">
          <p class="text-sm text-red-600 flex items-center">
            <.icon name="hero-exclamation-circle-solid" class="w-4 h-4 mr-2 flex-shrink-0" />
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
          phx-click={JS.push("close_reconnect_modal", target: @parent_target)}
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
