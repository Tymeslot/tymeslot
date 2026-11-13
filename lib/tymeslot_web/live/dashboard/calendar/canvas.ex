defmodule TymeslotWeb.Dashboard.Calendar.Canvas do
  @moduledoc """
  The element the `CalendarCanvas` hook draws the time grid into.

  `phx-update="ignore"` hands its children to the hook; the skeleton rendered
  here is the first paint, replaced as soon as the hook has its first payload.
  The translated copy travels in `data-strings` (see `ClientStrings`). Its
  columns follow the view's days, so a phone's three days paint as three
  columns before any script runs.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.Period

  attr :view, :atom, required: true
  attr :date, :any, required: true

  attr :days, :list,
    required: true,
    doc: "the days the view shows; a time grid has a skeleton column for each"

  attr :locale, :string, required: true
  attr :strings, :map, required: true
  attr :target, :any, required: true

  @spec canvas(map()) :: Phoenix.LiveView.Rendered.t()
  def canvas(assigns) do
    assigns = assign(assigns, :columns, skeleton_columns(assigns.view, assigns.days))

    ~H"""
    <div
      id="calendar-canvas"
      class="cal-canvas"
      phx-hook="CalendarCanvas"
      phx-update="ignore"
      phx-target={@target}
      data-view={@view}
      data-date={Date.to_iso8601(@date)}
      data-locale={@locale}
      data-strings={Jason.encode!(@strings)}
      aria-busy="true"
    >
      <div
        class="cal-grid is-loading"
        role="status"
        aria-label={dgettext("dashboard_calendar", "Loading calendar")}
      >
        <div class="cal-skeleton" style={"--cal-days:#{@columns}"}>
          <div :for={_column <- 1..@columns} class="cal-skeleton-col">
            <span class="cal-skeleton-block"></span>
            <span class="cal-skeleton-block is-short"></span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # A time grid's first paint has a column per day it shows (on a phone,
  # calendar-phone.css cuts it to three); month and agenda keep seven.
  defp skeleton_columns(view, days),
    do: if(Period.time_grid?(view), do: length(days), else: 7)
end
