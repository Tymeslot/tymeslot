defmodule TymeslotWeb.Dashboard.Calendar.Canvas do
  @moduledoc """
  The element the `CalendarCanvas` hook draws the time grid into.

  `phx-update="ignore"` hands its children to the hook; the skeleton rendered
  here is the first paint, replaced as soon as the hook has its first payload.
  The translated copy travels in `data-strings` (see `ClientStrings`).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :view, :atom, required: true
  attr :date, :any, required: true
  attr :locale, :string, required: true
  attr :strings, :map, required: true
  attr :target, :any, required: true

  @spec canvas(map()) :: Phoenix.LiveView.Rendered.t()
  def canvas(assigns) do
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
        <div class="cal-skeleton">
          <div :for={_column <- 1..7} class="cal-skeleton-col">
            <span class="cal-skeleton-block animate-shimmer"></span>
            <span class="cal-skeleton-block is-short animate-shimmer"></span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
