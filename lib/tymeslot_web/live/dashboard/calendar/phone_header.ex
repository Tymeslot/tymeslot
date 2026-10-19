defmodule TymeslotWeb.Dashboard.Calendar.PhoneHeader do
  @moduledoc """
  The calendar's header on a phone, in place of the toolbar: previous, the
  period, next and Today, each at least 44px. Rendered at every width and
  shown only below 40rem (`sm:hidden`), where the toolbar is hidden
  (`max-sm:hidden`), so a phone's first paint is right before any script
  runs. Its controls navigate like the toolbar's (`Navigation.js/3`).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Dashboard.Calendar.PeriodLabels

  @control "inline-flex h-11 min-w-11 shrink-0 items-center justify-center gap-1 rounded-token-lg text-tymeslot-700 hover:bg-tymeslot-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-turquoise-400"

  attr :view, :atom, required: true
  attr :date, :any, required: true
  attr :days, :list, required: true
  attr :today, :any, required: true
  attr :locale, :string, required: true

  @spec phone_header(map()) :: Phoenix.LiveView.Rendered.t()
  def phone_header(assigns) do
    assigns =
      assign(assigns,
        control: @control,
        title: PeriodLabels.short_title(assigns.view, assigns.date, assigns.days, assigns.locale)
      )

    ~H"""
    <div
      id="calendar-phone-header"
      class="flex shrink-0 items-center gap-0.5 border-b border-tymeslot-200 bg-white px-1 sm:hidden"
    >
      <button
        type="button"
        id="calendar-phone-prev"
        class={@control}
        aria-label={PeriodLabels.step_label(@view, :previous)}
        phx-click={Navigation.js(@view, Period.shift(@view, @date, -1), step: -1)}
      >
        <.icon name="hero-chevron-left" class="h-5 w-5" />
      </button>
      <span
        id="calendar-phone-title"
        class="min-w-0 flex-1 truncate text-center text-token-base font-semibold text-tymeslot-900"
      >
        {@title}
      </span>
      <button
        type="button"
        id="calendar-phone-next"
        class={@control}
        aria-label={PeriodLabels.step_label(@view, :next)}
        phx-click={Navigation.js(@view, Period.shift(@view, @date, 1), step: 1)}
      >
        <.icon name="hero-chevron-right" class="h-5 w-5" />
      </button>
      <button
        type="button"
        id="calendar-phone-today"
        class={[@control, "px-3 text-token-sm font-semibold"]}
        phx-click={Navigation.js(@view, @today, from: {@view, @date})}
      >
        {dgettext("dashboard_calendar", "Today")}
      </button>
    </div>
    """
  end
end
