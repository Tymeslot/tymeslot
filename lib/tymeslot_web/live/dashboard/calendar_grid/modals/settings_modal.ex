defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.SettingsModal do
  @moduledoc "Calendar settings modal for preferences like week start day, time format, and default view."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers

  attr :preferences, :any, required: true

  attr :desktop_permission, :string,
    default: nil,
    doc: "The browser's notification permission as the hook reported it, nil until it has"

  attr :desktop_permission_refused, :boolean,
    default: false,
    doc: "Whether the last attempt to switch reminders on was refused by the browser"

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
      <:header>{dgettext("dashboard_calendar_settings", "Calendar Settings")}</:header>

      <div class="space-y-5">
        <%!-- First day of week --%>
        <.preference_row>
          <:label>{dgettext("dashboard_calendar_settings", "First day of week")}</:label>
          <:description>
            {dgettext("dashboard_calendar_settings", "Start weeks on Monday or Sunday")}
          </:description>
          <.segmented_control
            id="week-start-toggle"
            size={:sm}
            value={safe_to_atom(@preferences.week_start_day, :monday)}
            on_change="update_week_start"
            param="option"
            target={@myself}
            aria_label={dgettext("dashboard_calendar_settings", "First day of week")}
          >
            <:option value={:monday} label={dgettext("dashboard_calendar_settings", "Mon")} />
            <:option value={:sunday} label={dgettext("dashboard_calendar_settings", "Sun")} />
          </.segmented_control>
        </.preference_row>

        <%!-- Time format --%>
        <.preference_row>
          <:label>{dgettext("dashboard_calendar_settings", "Time format")}</:label>
          <:description>
            {dgettext("dashboard_calendar_settings", "12-hour or 24-hour clock")}
          </:description>
          <.segmented_control
            id="time-format-toggle"
            size={:sm}
            value={safe_to_atom(PreferenceHelpers.time_format(@preferences), :"12h")}
            on_change="update_time_format"
            param="option"
            target={@myself}
            aria_label={dgettext("dashboard_calendar_settings", "Time format")}
          >
            <:option value={:"12h"} label={dgettext("dashboard_calendar_settings", "12h")} />
            <:option value={:"24h"} label={dgettext("dashboard_calendar_settings", "24h")} />
          </.segmented_control>
        </.preference_row>

        <%!-- Default view --%>
        <.preference_row>
          <:label>{dgettext("dashboard_calendar_settings", "Default view")}</:label>
          <:description>
            {dgettext("dashboard_calendar_settings", "Also switches the current view")}
          </:description>
          <.segmented_control
            id="default-view-toggle"
            size={:sm}
            value={safe_to_atom(@preferences.default_view, :week)}
            on_change="update_default_view"
            param="option"
            target={@myself}
            aria_label={dgettext("dashboard_calendar_settings", "Default view")}
          >
            <:option value={:day} label={dgettext("dashboard_calendar_settings", "Day")} />
            <:option value={:week} label={dgettext("dashboard_calendar_settings", "Week")} />
            <:option value={:month} label={dgettext("dashboard_calendar_settings", "Month")} />
          </.segmented_control>
        </.preference_row>

        <%!-- Show week numbers --%>
        <.preference_row>
          <:label>{dgettext("dashboard_calendar_settings", "Week numbers")}</:label>
          <:description>
            {dgettext("dashboard_calendar_settings", "Show ISO week numbers in month view")}
          </:description>
          <StatusSwitch.status_switch
            id="week-numbers-switch"
            checked={@preferences.show_week_numbers}
            on_change="toggle_week_numbers"
            target={@myself}
            size={:small}
          />
        </.preference_row>

        <%!-- Show weekends --%>
        <.preference_row>
          <:label>{dgettext("dashboard_calendar_settings", "Show weekends")}</:label>
          <:description>
            {dgettext("dashboard_calendar_settings", "Display Saturday and Sunday in week view")}
          </:description>
          <StatusSwitch.status_switch
            id="weekends-switch"
            checked={@preferences.show_weekends}
            on_change="toggle_weekends"
            target={@myself}
            size={:small}
          />
        </.preference_row>

        <%!-- Desktop reminders --%>
        <.preference_row>
          <:label>{dgettext("dashboard_calendar_settings", "Desktop reminders")}</:label>
          <:description>
            {dgettext(
              "dashboard_calendar_settings",
              "Show browser notifications before events while Tymeslot is open"
            )}
          </:description>
          <%!-- Switching on goes through the hook, which asks the browser for
                permission inside this click (a user gesture, which Firefox and
                Safari require) and reports the answer; switching off is the
                plain toggle. --%>
          <StatusSwitch.status_switch
            id="desktop-reminders-switch"
            checked={@preferences.desktop_reminders_enabled}
            on_change="toggle_desktop_reminders"
            target={@myself}
            size={:small}
            phx-hook="DesktopReminderPermission"
            data-report-event="desktop_reminders_permission"
            data-enable-event="enable_desktop_reminders"
          />
        </.preference_row>
        <.desktop_permission_note
          permission={@desktop_permission}
          enabled={@preferences.desktop_reminders_enabled}
          refused={@desktop_permission_refused}
        />
      </div>
    </.modal>
    """
  end

  attr :permission, :string, required: true
  attr :enabled, :boolean, required: true
  attr :refused, :boolean, required: true

  # What the browser's permission means for the switch above. A `default`
  # permission with reminders already on (a preference saved before the switch
  # asked) gets a button, which is the user gesture the request needs.
  defp desktop_permission_note(%{permission: "denied"} = assigns) do
    ~H"""
    <p id="desktop-permission-note" role="status" class="text-token-sm text-amber-700 -mt-3">
      {dgettext(
        "dashboard_calendar_settings",
        "Blocked in your browser settings. Allow notifications for this site there, then switch reminders on again."
      )}
    </p>
    """
  end

  defp desktop_permission_note(%{permission: "unsupported"} = assigns) do
    ~H"""
    <p id="desktop-permission-note" role="status" class="text-token-sm text-amber-700 -mt-3">
      {dgettext("dashboard_calendar_settings", "This browser does not support notifications.")}
    </p>
    """
  end

  defp desktop_permission_note(%{permission: "default", enabled: true} = assigns) do
    ~H"""
    <div id="desktop-permission-note" role="status" class="-mt-3 space-y-2">
      <p class="text-token-sm text-amber-700">
        {dgettext(
          "dashboard_calendar_settings",
          "Reminders are on, but your browser has not allowed notifications yet."
        )}
      </p>
      <button
        id="desktop-reminders-grant"
        type="button"
        phx-hook="DesktopReminderPermission"
        data-report-event="desktop_reminders_permission"
        data-enable-event="enable_desktop_reminders"
        class="text-token-sm font-semibold text-turquoise-700 underline hover:text-turquoise-800"
      >
        {dgettext("dashboard_calendar_settings", "Allow notifications")}
      </button>
    </div>
    """
  end

  defp desktop_permission_note(%{permission: "default", refused: true} = assigns) do
    ~H"""
    <p id="desktop-permission-note" role="status" class="text-token-sm text-amber-700 -mt-3">
      {dgettext(
        "dashboard_calendar_settings",
        "Notifications were not allowed, so reminders are still off."
      )}
    </p>
    """
  end

  defp desktop_permission_note(assigns), do: ~H""

  slot :label, required: true
  slot :description, required: true
  slot :inner_block, required: true, doc: "The row's control"

  # The text column takes the remaining width and wraps (`min-w-0`); the
  # control keeps its natural size (`shrink-0`), so a long description wraps
  # beside it instead of running underneath it.
  defp preference_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4" data-testid="preference-row">
      <div class="min-w-0 flex-1">
        <p class="text-token-sm font-medium text-tymeslot-700">{render_slot(@label)}</p>
        <p class="text-token-xs text-tymeslot-400">{render_slot(@description)}</p>
      </div>
      <div class="shrink-0" data-testid="preference-control">{render_slot(@inner_block)}</div>
    </div>
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
