defmodule TymeslotWeb.Dashboard.Calendar.DisplayOptions do
  @moduledoc """
  The calendar's display options, drawn once for the two places that offer
  them: the toolbar's dropdown (`id_prefix` "calendar") and the foot of the
  Calendars sheet, where the toolbar is hidden ("calendar-sheet"). Each
  control sends the same event from either place (`PowerEvents` routes it to
  `DisplayPreferences`), so the two lists cannot drift apart.

  The rows sit above a footer of rare actions.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Helpers.LocaleFormat

  # Phones and coarse pointers get a 44px hit area on every row: the row is
  # at least 44px tall and segments stretch to it. A switch needs nothing
  # here: `.status-toggle::before` already pads it to 44x44 on coarse pointers.
  @row "max-sm:min-h-11 pointer-coarse:min-h-11"
  # A row of segments wraps them under its label rather than clipping them
  # when a translation is long (German needs about 340px for Density).
  @segment_row "flex flex-wrap items-center justify-between gap-x-3 gap-y-2"
  @segments "ml-auto max-sm:[&>button]:min-h-11 max-sm:[&>button]:px-3 pointer-coarse:[&>button]:min-h-11 pointer-coarse:[&>button]:px-3"

  attr :id_prefix, :string,
    required: true,
    doc: ~s(prefixes every id: "calendar" in the toolbar, "calendar-sheet" in the sheet)

  attr :preferences, :map, required: true, doc: "the organiser's `CalendarPreferencesSchema`"
  attr :time_format, :string, required: true, doc: ~s("24h" or "12h": the surface's `time_format`)

  attr :calendar_focus, :boolean,
    default: false,
    doc:
      "focus mode's stored value, from `DashboardLive` (the sheet, phones only, leaves it false)"

  attr :target, :any, required: true

  @spec display_options(map()) :: Phoenix.LiveView.Rendered.t()
  def display_options(assigns) do
    ~H"""
    <div id={"#{@id_prefix}-display-rows"} class="space-y-4">
      <div class={[segment_row(), row()]}>
        <span class="text-token-sm font-medium text-tymeslot-700">
          {dgettext("dashboard_calendar", "Density")}
        </span>
        <.segmented_control
          id={"#{@id_prefix}-density"}
          size={:sm}
          class={segments()}
          value={@preferences.density}
          on_change="calendar:set_density"
          param="option"
          target={@target}
          aria_label={dgettext("dashboard_calendar", "Density")}
        >
          <:option value="comfortable" label={dgettext("dashboard_calendar", "Comfortable")} />
          <:option value="compact" label={dgettext("dashboard_calendar", "Compact")} />
        </.segmented_control>
      </div>
      <div class={["flex items-center justify-between gap-3", row()]}>
        <span class="text-token-sm font-medium text-tymeslot-700">
          {dgettext("dashboard_calendar", "Fold early hours")}
        </span>
        <StatusSwitch.status_switch
          id={"#{@id_prefix}-fold-night"}
          checked={@preferences.fold_night}
          on_change="calendar:toggle_fold_night"
          target={@target}
          size={:small}
          aria_label={dgettext("dashboard_calendar", "Fold early hours")}
        />
      </div>
      <.week_rows
        id_prefix={@id_prefix}
        preferences={@preferences}
        time_format={@time_format}
        target={@target}
      />
      <%!-- Below 1024px focus mode changes nothing, so the row is hidden.
           No target: DashboardLive owns the layout. --%>
      <div
        id={"#{@id_prefix}-focus-row"}
        class={["hidden items-center justify-between gap-3 lg:flex", row()]}
      >
        <span class="text-token-sm font-medium text-tymeslot-700">
          {dgettext("dashboard_calendar_power", "Focus mode")}
        </span>
        <StatusSwitch.status_switch
          id={"#{@id_prefix}-focus"}
          checked={@calendar_focus}
          on_change="calendar:toggle_focus"
          size={:small}
          aria_label={dgettext("dashboard_calendar_power", "Focus mode")}
          aria-keyshortcuts="f"
        />
      </div>
      <div class="flex flex-col items-start gap-1 border-t border-tymeslot-100 pt-3">
        <.action_button
          id={"#{@id_prefix}-import-ics"}
          variant={:ghost}
          size={:sm}
          class="max-sm:min-h-11 pointer-coarse:min-h-11"
          phx-click={JS.push("calendar:ics_open", value: %{return: "display"}, target: @target)}
        >
          {dgettext("dashboard_calendar_power", "Import an .ics file")}
        </.action_button>
        <.action_button
          id={"#{@id_prefix}-shortcuts-button"}
          variant={:ghost}
          size={:sm}
          class="max-sm:min-h-11 pointer-coarse:min-h-11"
          phx-click={
            JS.push("calendar:toggle_menu",
              value: %{menu: "shortcuts", return: "display"},
              target: @target
            )
          }
        >
          {dgettext("dashboard_calendar", "Keyboard shortcuts")}
        </.action_button>
      </div>
    </div>
    """
  end

  defp row, do: @row
  defp segments, do: @segments
  defp segment_row, do: @segment_row

  # Rows 3 to 7: what the week shows and how times read. Weekends and the
  # week start reload the window; the others redraw from the settings (see
  # `DisplayPreferences`).
  attr :id_prefix, :string, required: true
  attr :preferences, :map, required: true
  attr :time_format, :string, required: true
  attr :target, :any, required: true

  defp week_rows(assigns) do
    [sunday, monday | _rest] =
      LocaleFormat.get_weekday_names(Gettext.get_locale(TymeslotWeb.Gettext), :full)

    assigns =
      assign(assigns,
        monday: monday,
        sunday: sunday,
        week_start: Atom.to_string(Period.week_start(assigns.preferences.week_start_day))
      )

    ~H"""
    <.switch_row
      id={"#{@id_prefix}-weekends"}
      label={dgettext("dashboard_calendar_power", "Include weekends")}
      description={dgettext("dashboard_calendar_power", "In the week view")}
      checked={@preferences.show_weekends}
      event="calendar:toggle_weekends"
      target={@target}
    />
    <.switch_row
      id={"#{@id_prefix}-week-numbers"}
      label={dgettext("dashboard_calendar_power", "Show week numbers")}
      checked={@preferences.show_week_numbers}
      event="calendar:toggle_week_numbers"
      target={@target}
    />
    <div class={[segment_row(), row()]}>
      <span class="text-token-sm font-medium text-tymeslot-700">
        {dgettext("dashboard_calendar_power", "Week starts on")}
      </span>
      <.segmented_control
        id={"#{@id_prefix}-week-start"}
        size={:sm}
        class={segments()}
        value={@week_start}
        on_change="calendar:set_week_start"
        param="option"
        target={@target}
        aria_label={dgettext("dashboard_calendar_power", "Week starts on")}
      >
        <:option value="monday" label={@monday} />
        <:option value="sunday" label={@sunday} />
      </.segmented_control>
    </div>
    <div class={[segment_row(), row()]}>
      <span class="text-token-sm font-medium text-tymeslot-700">
        {dgettext("dashboard_calendar_power", "Clock")}
      </span>
      <.segmented_control
        id={"#{@id_prefix}-time-format"}
        size={:sm}
        class={segments()}
        value={@time_format}
        on_change="calendar:set_time_format"
        param="option"
        target={@target}
        aria_label={dgettext("dashboard_calendar_power", "Clock")}
      >
        <:option value="24h" label={dgettext("dashboard_calendar_power", "24-hour")} />
        <:option value="12h" label={dgettext("dashboard_calendar_power", "12-hour")} />
      </.segmented_control>
    </div>
    <.switch_row
      id={"#{@id_prefix}-desktop-reminders"}
      label={dgettext("dashboard_calendar_power", "Desktop notifications")}
      description={
        dgettext(
          "dashboard_calendar_power",
          "Before events with a reminder, while the calendar is open"
        )
      }
      checked={@preferences.desktop_reminders_enabled}
      event="calendar:toggle_desktop_reminders"
      target={@target}
    />
    """
  end

  # A label, an optional description read with the switch, and the switch.
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, default: nil
  attr :checked, :boolean, required: true
  attr :event, :string, required: true
  attr :target, :any, required: true

  defp switch_row(assigns) do
    ~H"""
    <div class={["flex items-start justify-between gap-3", row()]}>
      <div class="min-w-0">
        <span class="block text-token-sm font-medium text-tymeslot-700">{@label}</span>
        <span
          :if={@description}
          id={"#{@id}-description"}
          class="block text-token-xs text-tymeslot-500"
        >
          {@description}
        </span>
      </div>
      <StatusSwitch.status_switch
        id={@id}
        checked={@checked}
        on_change={@event}
        target={@target}
        size={:small}
        aria_label={@label}
        aria-describedby={@description && "#{@id}-description"}
      />
    </div>
    """
  end
end
