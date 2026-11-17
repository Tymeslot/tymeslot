defmodule TymeslotWeb.Dashboard.Calendar.DateSheet do
  @moduledoc """
  The phone's date picker, opened from the period in the phone header: a
  month of days (`MiniMonth`, each a 44px target) and Today, in a core
  modal, so a bottom sheet on a phone. A day navigates like every other
  control (`Navigation.js/3`), keeping the view; the patch's answer closes
  the sheet, and a click that changes nothing closes it in the patch's
  place.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Dashboard.Calendar.MiniMonth
  alias TymeslotWeb.Dashboard.Calendar.Navigation

  attr :mini_cursor, :any, required: true
  attr :view, :atom, required: true
  attr :date, :any, required: true
  attr :days, :list, required: true
  attr :today, :any, required: true
  attr :week_start, :atom, required: true
  attr :locale, :string, required: true
  attr :target, :any, required: true
  attr :week_numbers, :boolean, default: false

  @spec date_sheet(map()) :: Phoenix.LiveView.Rendered.t()
  def date_sheet(assigns) do
    assigns = assign(assigns, :close, JS.push("calendar:close_menu", target: assigns.target))

    ~H"""
    <.modal id="calendar-date-sheet" show size={:small} on_cancel={@close}>
      <:header>{dgettext("dashboard_calendar", "Choose a date")}</:header>
      <%!-- On a phone the modal body pads 40px a side, which would squeeze seven
           days below 44px at 360px: the month bleeds into that padding. --%>
      <div class="-mx-10 px-1 sm:mx-0 sm:px-0">
        <MiniMonth.mini_month
          id="calendar-sheet-month"
          size={:touch}
          cursor={@mini_cursor}
          view={@view}
          date={@date}
          days={@days}
          today={@today}
          week_start={@week_start}
          locale={@locale}
          target={@target}
          week_numbers={@week_numbers}
        />
      </div>
      <:footer>
        <.action_button
          id="calendar-sheet-today"
          variant={:secondary}
          class="w-full"
          phx-click={Navigation.js(@view, @today, from: {@view, @date}, unchanged: @close)}
        >
          {dgettext("dashboard_calendar", "Today")}
        </.action_button>
      </:footer>
    </.modal>
    """
  end
end
