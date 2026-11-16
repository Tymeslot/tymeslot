defmodule TymeslotWeb.Dashboard.Calendar.CalendarsSheet do
  @moduledoc """
  The rail's calendars and layers wherever the rail is hidden (below
  768px): opened from the phone header's Calendars button, or from the
  toolbar's between 640 and 767px. A core modal, so a bottom sheet on a
  phone.

  The calendar sets sit above the calendars, as in the rail; while a set is
  active they mark it and offer No set, so the hidden-calendars row gives way.

  While calendars are hidden its first row says how many and shows them
  all, since the phone header has no room for the toolbar's filter chip.
  The display options (`DisplayOptions`, the toolbar's own) sit at its
  foot, since a phone has no toolbar, with the time zone every time is
  shown in (`ZoneLink`), which the rail shows on a desktop. Every control
  sends the event the rail's or the toolbar's does, so the grid behind changes at once and the
  sheet stays open.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Dashboard.Calendar.DisplayOptions
  alias TymeslotWeb.Dashboard.Calendar.Rail
  alias TymeslotWeb.Dashboard.Calendar.RailLayers
  alias TymeslotWeb.Dashboard.Calendar.RailSets
  alias TymeslotWeb.Dashboard.Calendar.ZoneLink

  attr :accounts, :list, required: true
  attr :hidden_count, :integer, required: true
  attr :set_view, :map, required: true, doc: "see `RailSets.view/1`"
  attr :syncing_ids, :any, default: MapSet.new()
  attr :problem_ids, :any, default: MapSet.new()
  attr :reauth_ids, :any, default: MapSet.new()
  attr :bookable, :map, required: true, doc: "see `LayerChoices.rail/2`"
  attr :preferences, :map, required: true, doc: "the organiser's `CalendarPreferencesSchema`"
  attr :time_format, :string, required: true, doc: ~s("24h" or "12h")
  attr :timezone, :string, required: true, doc: "the zone the surface reads times in"
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
          :if={@hidden_count > 0 and is_nil(@set_view.name)}
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
        <RailSets.sets
          id_prefix="calendar-sheet"
          sets={@set_view.sets}
          active_position={@set_view.active_position}
          editor={@set_view.editor}
          target={@target}
        />
        <Rail.calendar_list
          id_prefix="calendar-sheet"
          accounts={@accounts}
          syncing_ids={@syncing_ids}
          problem_ids={@problem_ids}
          reauth_ids={@reauth_ids}
          set_active={not is_nil(@set_view.name)}
          spell_out
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
          <DisplayOptions.display_options
            id_prefix="calendar-sheet"
            preferences={@preferences}
            time_format={@time_format}
            target={@target}
          />
          <ZoneLink.zone_link id="calendar-sheet-timezone" timezone={@timezone} class="px-1" />
        </section>
      </div>
    </.modal>
    """
  end
end
