defmodule TymeslotWeb.Dashboard.Calendar.DisplayOptions do
  @moduledoc """
  The calendar's display options, drawn once for the two places that offer
  them: the toolbar's dropdown (`id_prefix` "calendar") and the foot of the
  Calendars sheet, where the toolbar is hidden ("calendar-sheet"). Each
  control sends the same event from either place (`PowerEvents` routes it to
  `DisplayPreferences`), so the two lists cannot drift apart.

  The rows sit above a footer of rare actions. The way back to the old
  calendar has no `phx-target`: `DashboardLive` swaps the component.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.UI.StatusSwitch

  attr :id_prefix, :string,
    required: true,
    doc: ~s(prefixes every id: "calendar" in the toolbar, "calendar-sheet" in the sheet)

  attr :preferences, :map, required: true, doc: "the organiser's `CalendarPreferencesSchema`"
  attr :target, :any, required: true

  @spec display_options(map()) :: Phoenix.LiveView.Rendered.t()
  def display_options(assigns) do
    ~H"""
    <div id={"#{@id_prefix}-display-rows"} class="space-y-4">
      <div class="flex items-center justify-between gap-3">
        <span class="text-token-sm font-medium text-tymeslot-700">
          {dgettext("dashboard_calendar", "Density")}
        </span>
        <.segmented_control
          id={"#{@id_prefix}-density"}
          size={:sm}
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
      <div class="flex items-center justify-between gap-3">
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
      <div class="flex flex-col items-start gap-1 border-t border-tymeslot-100 pt-3">
        <%!-- No phx-target: DashboardLive swaps the component. --%>
        <.action_button
          id={"#{@id_prefix}-back-to-old"}
          variant={:ghost}
          size={:sm}
          phx-click={JS.push("calendar:switch_surface", value: %{enabled: false})}
        >
          {dgettext("dashboard_calendar", "Back to the old calendar")}
        </.action_button>
      </div>
    </div>
    """
  end
end
