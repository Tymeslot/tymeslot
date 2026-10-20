defmodule TymeslotWeb.Dashboard.Calendar.PhoneTabs do
  @moduledoc """
  The calendar's bottom tabs on a phone (Agenda, Day, 3 days, Month, in
  `Period.phone_views/0` order) and the + button above them, in thumb reach.
  The tab bar is the surface's last child, in normal flow, so nothing needs
  padding to clear it; only the + button floats (`calendar-phone.css`). Both
  are rendered at every width and shown only below 40rem.

  A week shows as three days on a phone, so the 3 days tab is current while
  a week is shown: between a wrong first guess at the width and the hook's
  first report, the tabs still say where the organiser is.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Dashboard.Calendar.PeriodLabels

  @icons %{
    agenda: "hero-list-bullet",
    day: "hero-calendar",
    three_day: "hero-view-columns",
    month: "hero-calendar-days"
  }

  attr :view, :atom, required: true
  attr :date, :any, required: true

  @spec phone_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def phone_tabs(assigns) do
    assigns = assign(assigns, tabs: Period.phone_views(), icons: @icons)

    ~H"""
    <button
      type="button"
      id="calendar-fab"
      class="cal-fab inline-flex items-center justify-center rounded-token-full bg-turquoise-700 text-white shadow-lg hover:bg-turquoise-800 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400 focus-visible:ring-offset-2 sm:hidden"
      aria-label={dgettext("dashboard_calendar_editing", "New event")}
      aria-keyshortcuts="c"
      phx-click={JS.dispatch("calendar:quick-create", to: "#calendar-canvas")}
    >
      <.icon name="hero-plus" class="h-7 w-7" />
    </button>
    <nav
      id="calendar-tabs"
      aria-label={dgettext("dashboard_calendar", "Views")}
      class="cal-tabs flex shrink-0 border-t border-tymeslot-200 bg-white sm:hidden"
    >
      <button
        :for={tab <- @tabs}
        type="button"
        id={"calendar-tab-#{tab}"}
        aria-current={current?(tab, @view) && "page"}
        phx-click={Navigation.js(tab, @date, from: {@view, @date})}
        class={[
          "flex min-h-11 flex-1 flex-col items-center justify-center gap-0.5 text-token-xs font-semibold",
          "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-turquoise-400",
          if(current?(tab, @view),
            do: "text-turquoise-700",
            else: "text-tymeslot-500 hover:text-tymeslot-800"
          )
        ]}
      >
        <.icon name={@icons[tab]} class="h-6 w-6" />
        <span>{PeriodLabels.view_label(tab)}</span>
      </button>
    </nav>
    """
  end

  defp current?(:three_day, :week), do: true
  defp current?(tab, view), do: tab == view
end
