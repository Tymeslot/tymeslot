defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.SettingsModal do
  @moduledoc "Calendar settings modal for preferences like week start day, time format, and default view."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Components.UI.Toggle
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers

  attr :preferences, :any, required: true
  attr :myself, :any, required: true

  @spec settings_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_modal(assigns) do
    ~H"""
    <.modal
      id="calendar-settings-modal"
      show={true}
      on_cancel={JS.push("close_settings", target: @myself)}
      size={:small}
    >
      <:header>{dgettext("dashboard_calendar_events", "Calendar Settings")}</:header>

      <div class="space-y-5">
        <%!-- First day of week --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_calendar_events", "First day of week")}
            </p>
            <p class="text-token-xs text-tymeslot-400">
              {dgettext("dashboard_calendar_events", "Start weeks on Monday or Sunday")}
            </p>
          </div>
          <Toggle.toggle
            id="week-start-toggle"
            active_option={safe_to_atom(@preferences.week_start_day, :monday)}
            phx_click="update_week_start"
            phx_target={@myself}
            options={[
              %{value: :monday, label: dgettext("dashboard_calendar_events", "Mon")},
              %{value: :sunday, label: dgettext("dashboard_calendar_events", "Sun")}
            ]}
            size={:small}
          />
        </div>

        <%!-- Time format --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_calendar_events", "Time format")}
            </p>
            <p class="text-token-xs text-tymeslot-400">
              {dgettext("dashboard_calendar_events", "12-hour or 24-hour clock")}
            </p>
          </div>
          <Toggle.toggle
            id="time-format-toggle"
            active_option={safe_to_atom(PreferenceHelpers.time_format(@preferences), :"12h")}
            phx_click="update_time_format"
            phx_target={@myself}
            options={[
              %{value: :"12h", label: dgettext("dashboard_calendar_events", "12h")},
              %{value: :"24h", label: dgettext("dashboard_calendar_events", "24h")}
            ]}
            size={:small}
          />
        </div>

        <%!-- Default view --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_calendar_events", "Default view")}
            </p>
            <p class="text-token-xs text-tymeslot-400">
              {dgettext("dashboard_calendar_events", "Also switches the current view")}
            </p>
          </div>
          <Toggle.toggle
            id="default-view-toggle"
            active_option={safe_to_atom(@preferences.default_view, :week)}
            phx_click="update_default_view"
            phx_target={@myself}
            options={[
              %{value: :day, label: dgettext("dashboard_calendar_events", "Day")},
              %{value: :week, label: dgettext("dashboard_calendar_events", "Week")},
              %{value: :month, label: dgettext("dashboard_calendar_events", "Month")}
            ]}
            size={:small}
          />
        </div>

        <%!-- Show week numbers --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_calendar_events", "Week numbers")}
            </p>
            <p class="text-token-xs text-tymeslot-400">
              {dgettext("dashboard_calendar_events", "Show ISO week numbers in month view")}
            </p>
          </div>
          <StatusSwitch.status_switch
            id="week-numbers-switch"
            checked={@preferences.show_week_numbers}
            on_change="toggle_week_numbers"
            target={@myself}
            size={:small}
          />
        </div>

        <%!-- Show weekends --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_calendar_events", "Show weekends")}
            </p>
            <p class="text-token-xs text-tymeslot-400">
              {dgettext("dashboard_calendar_events", "Display Saturday and Sunday in week view")}
            </p>
          </div>
          <StatusSwitch.status_switch
            id="weekends-switch"
            checked={@preferences.show_weekends}
            on_change="toggle_weekends"
            target={@myself}
            size={:small}
          />
        </div>

        <%!-- Desktop reminders --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_calendar_events", "Desktop reminders")}
            </p>
            <p class="text-token-xs text-tymeslot-400">
              {dgettext(
                "dashboard_calendar_events",
                "Show browser notifications before events while Tymeslot is open"
              )}
            </p>
          </div>
          <StatusSwitch.status_switch
            id="desktop-reminders-switch"
            checked={@preferences.desktop_reminders_enabled}
            on_change="toggle_desktop_reminders"
            target={@myself}
            size={:small}
          />
        </div>
      </div>
    </.modal>
    """
  end

  @allowed_atoms %{
    "monday" => :monday,
    "sunday" => :sunday,
    "12h" => :"12h",
    "24h" => :"24h",
    "day" => :day,
    "week" => :week,
    "month" => :month
  }

  defp safe_to_atom(value, default) when is_binary(value) do
    Map.get(@allowed_atoms, value, default)
  end

  defp safe_to_atom(_value, default), do: default
end
