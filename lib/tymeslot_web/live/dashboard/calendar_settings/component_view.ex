defmodule TymeslotWeb.Dashboard.CalendarSettings.ComponentView do
  @moduledoc """
  Markup for the calendar settings component.

  Extracted from `CalendarSettingsComponent` so that module stays focused on
  lifecycle and event routing, matching how `CalendarGrid.ComponentView` sits
  behind `CalendarGridComponent`. `settings/1` receives the component's assigns
  unchanged (its `render/1` delegates straight to it), so LiveView change
  tracking is preserved.

  The picker groups come from `ProviderPicker`, which owns how provider
  descriptors are categorised for that one modal.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavReconnectModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.CalendarSelectionModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ProviderPickerModal
  alias TymeslotWeb.Dashboard.CalendarSettings.Components
  alias TymeslotWeb.Dashboard.CalendarSettings.ConfigViewComponent
  alias TymeslotWeb.Dashboard.CalendarSettings.ProviderPicker

  @doc "Renders calendar settings: the connected list, the free/busy feed, and the modal stack."
  @spec settings(map()) :: Phoenix.LiveView.Rendered.t()
  def settings(assigns) do
    ~H"""
    <div class="space-y-12 pb-24">
      <div class="flex items-center justify-between gap-4 flex-wrap">
        <.section_header
          icon="hero-calendar-days"
          title={dgettext("dashboard_calendar_settings", "Calendar Settings")}
        />
        <%!-- With nothing connected, the empty state below carries the action. --%>
        <.connect_button :if={@integrations != []} myself={@myself} />
      </div>

      <div class="space-y-12">
        <div>
          <%= if @integrations == [] do %>
            <.no_calendars_yet myself={@myself} />
          <% else %>
            <Components.connected_calendars_section
              integrations={@integrations}
              is_refreshing={@is_refreshing}
              myself={@myself}
              health_states={@health_states}
            />
          <% end %>
        </div>

        <Components.freebusy_section
          enabled={@freebusy_enabled}
          url={@freebusy_url}
          myself={@myself}
        />
      </div>

      <ProviderPickerModal.provider_picker_modal
        id="calendar-provider-picker"
        show={@show_picker}
        title={dgettext("dashboard_calendar_settings", "Connect a calendar")}
        subtitle={
          dgettext(
            "dashboard_calendar_settings",
            "Sync your availability to prevent double bookings."
          )
        }
        target={@myself}
        on_cancel={JS.push("hide_picker", target: @myself)}
        groups={ProviderPicker.groups(@available_calendar_providers, @integrations)}
        config_active={@selected_provider != nil}
        back_event="back_to_grid"
      >
        <:config>
          <.live_component
            :if={@selected_provider != nil}
            module={ConfigViewComponent}
            id="calendar-config-view-component"
            selected_provider={@selected_provider}
            current_user={@current_user}
            security_metadata={@security_metadata}
          />
        </:config>
      </ProviderPickerModal.provider_picker_modal>

      <CalendarSelectionModal.calendar_selection_modal
        id="calendar-selection"
        show={@managing_calendar_id != nil}
        integration={Enum.find(@integrations, &(&1.id == @managing_calendar_id))}
        target={@myself}
        on_cancel={JS.push("close_manage_calendars", target: @myself)}
      />

      <.live_component
        module={DeleteIntegrationModal}
        id="delete-calendar-modal"
        integration_type={:calendar}
        current_user={@current_user}
      />

      <.live_component
        module={CaldavReconnectModal}
        id="caldav-reconnect-modal"
        current_user={@current_user}
      />
    </div>
    """
  end

  attr :myself, :any, required: true

  defp no_calendars_yet(assigns) do
    ~H"""
    <.empty_state
      icon="hero-calendar-days"
      size={:lg}
      data-testid="calendars-empty"
      title={dgettext("dashboard_calendar_settings", "No calendars connected yet")}
      description={
        dgettext(
          "dashboard_calendar_settings",
          "Connect a calendar so Tymeslot can read your availability and stop meetings being booked when you're already busy."
        )
      }
    >
      <:action><.connect_button myself={@myself} /></:action>
    </.empty_state>
    """
  end

  # The header and the empty state offer the same action, so it is defined once.
  attr :myself, :any, required: true

  defp connect_button(assigns) do
    ~H"""
    <.action_button
      size={:sm}
      icon="hero-plus"
      class="shrink-0"
      phx-click="show_picker"
      phx-target={@myself}
    >
      {dgettext("dashboard_calendar_settings", "Connect a calendar")}
    </.action_button>
    """
  end
end
