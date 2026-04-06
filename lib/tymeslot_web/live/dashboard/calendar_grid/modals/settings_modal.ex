defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.SettingsModal do
  @moduledoc "Calendar settings modal for preferences like week start day, time format, and default view."

  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Components.UI.Toggle

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
      <:header>Calendar Settings</:header>

      <div class="space-y-5">
        <%!-- First day of week --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">First day of week</p>
            <p class="text-token-xs text-tymeslot-400">Start weeks on Monday or Sunday</p>
          </div>
          <Toggle.toggle
            id="week-start-toggle"
            active_option={safe_to_atom(@preferences.week_start_day, :monday)}
            phx_click="update_week_start"
            phx_target={@myself}
            options={[%{value: :monday, label: "Mon"}, %{value: :sunday, label: "Sun"}]}
            size={:small}
          />
        </div>

        <%!-- Time format --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">Time format</p>
            <p class="text-token-xs text-tymeslot-400">12-hour or 24-hour clock</p>
          </div>
          <Toggle.toggle
            id="time-format-toggle"
            active_option={safe_to_atom(@preferences.time_format, :"12h")}
            phx_click="update_time_format"
            phx_target={@myself}
            options={[%{value: :"12h", label: "12h"}, %{value: :"24h", label: "24h"}]}
            size={:small}
          />
        </div>

        <%!-- Default view --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">Default view</p>
            <p class="text-token-xs text-tymeslot-400">Also switches the current view</p>
          </div>
          <Toggle.toggle
            id="default-view-toggle"
            active_option={safe_to_atom(@preferences.default_view, :week)}
            phx_click="update_default_view"
            phx_target={@myself}
            options={[
              %{value: :day, label: "Day"},
              %{value: :week, label: "Week"},
              %{value: :month, label: "Month"}
            ]}
            size={:small}
          />
        </div>

        <%!-- Show week numbers --%>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-token-sm font-medium text-tymeslot-700">Week numbers</p>
            <p class="text-token-xs text-tymeslot-400">Show ISO week numbers in month view</p>
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
            <p class="text-token-sm font-medium text-tymeslot-700">Show weekends</p>
            <p class="text-token-xs text-tymeslot-400">Display Saturday and Sunday in week view</p>
          </div>
          <StatusSwitch.status_switch
            id="weekends-switch"
            checked={@preferences.show_weekends}
            on_change="toggle_weekends"
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
