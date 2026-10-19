defmodule TymeslotWeb.Dashboard.Calendar.CalendarsSheet do
  @moduledoc """
  The rail's calendars and layers wherever the rail is hidden (below
  768px): opened from the phone header's Calendars button, or from the
  toolbar's between 640 and 767px. A core modal, so a bottom sheet on a
  phone.

  While calendars are hidden its first row says how many and shows them
  all, since the phone header has no room for the toolbar's filter chip.
  The display options (density, the folded early hours and the way back to
  the old calendar) sit at its foot, since a phone has no toolbar. Every
  control sends the event the rail's or the toolbar's does, so the grid
  behind changes at once and the sheet stays open.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Dashboard.Calendar.Rail
  alias TymeslotWeb.Dashboard.Calendar.RailLayers

  attr :accounts, :list, required: true
  attr :hidden_count, :integer, required: true
  attr :syncing_ids, :any, default: MapSet.new()
  attr :problem_ids, :any, default: MapSet.new()
  attr :reauth_ids, :any, default: MapSet.new()
  attr :bookable, :map, required: true, doc: "see `LayerChoices.rail/2`"
  attr :density, :string, required: true
  attr :fold_night, :boolean, required: true
  attr :target, :any, required: true

  @spec calendars_sheet(map()) :: Phoenix.LiveView.Rendered.t()
  def calendars_sheet(assigns) do
    ~H"""
    <.modal
      id="calendar-calendars-sheet"
      show
      on_cancel={JS.push("calendar:close_menu", target: @target)}
    >
      <:header>{dgettext("dashboard_calendar", "Calendars")}</:header>
      <div class="cal-sheet-list space-y-5">
        <div
          :if={@hidden_count > 0}
          id="calendar-sheet-hidden"
          class="flex items-center gap-3 rounded-token-lg border border-amber-300 bg-amber-50 py-1 pl-3 pr-1 text-token-sm font-semibold text-amber-900"
        >
          <span class="min-w-0 flex-1">
            {dngettext(
              "dashboard_calendar",
              "%{count} calendar hidden",
              "%{count} calendars hidden",
              @hidden_count
            )}
          </span>
          <button
            type="button"
            id="calendar-sheet-show-all"
            phx-click="calendar:show_all"
            phx-target={@target}
            class="inline-flex min-h-11 items-center rounded-token-md px-3 underline hover:bg-amber-100 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-amber-500"
          >
            {dgettext("dashboard_calendar", "Show all calendars")}
          </button>
        </div>
        <Rail.calendar_list
          id_prefix="calendar-sheet"
          show_heading={false}
          accounts={@accounts}
          syncing_ids={@syncing_ids}
          problem_ids={@problem_ids}
          reauth_ids={@reauth_ids}
          target={@target}
        />
        <RailLayers.layers id_prefix="calendar-sheet" bookable={@bookable} target={@target} />
        <section
          id="calendar-sheet-display"
          aria-labelledby="calendar-sheet-display-heading"
          class="space-y-4 border-t border-tymeslot-100 pt-4"
        >
          <h2
            id="calendar-sheet-display-heading"
            class="text-token-xs font-semibold uppercase tracking-wide text-tymeslot-500"
          >
            {dgettext("dashboard_calendar", "Display options")}
          </h2>
          <div class="flex items-center justify-between gap-3">
            <span class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_calendar", "Density")}
            </span>
            <.segmented_control
              id="calendar-sheet-density"
              size={:sm}
              value={@density}
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
              id="calendar-sheet-fold-night"
              checked={@fold_night}
              on_change="calendar:toggle_fold_night"
              target={@target}
              size={:small}
              aria_label={dgettext("dashboard_calendar", "Fold early hours")}
            />
          </div>
          <%!-- No phx-target: DashboardLive swaps the component. --%>
          <.action_button
            id="calendar-sheet-back-to-old"
            variant={:ghost}
            size={:sm}
            phx-click={JS.push("calendar:switch_surface", value: %{enabled: false})}
          >
            {dgettext("dashboard_calendar", "Back to the old calendar")}
          </.action_button>
        </section>
      </div>
    </.modal>
    """
  end
end
