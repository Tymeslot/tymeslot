defmodule TymeslotWeb.Dashboard.Calendar.PhoneHeader do
  @moduledoc """
  The calendar's header on a phone, in place of the toolbar: previous, the
  period on one line (which opens `DateSheet`), next, search (the command
  bar), Today (today's date on a tile) and Calendars (which turns amber with the active set's name, or a count
  while calendars are hidden), each at least 44px.
  Rendered at every width and shown only below 40rem (`sm:hidden`), where
  the toolbar is hidden (`max-sm:hidden`), so a phone's first paint is
  right before any script runs. Its controls navigate like the toolbar's
  (`Navigation.js/3`).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Dashboard.Calendar.PeriodLabels

  @control "inline-flex h-11 min-w-11 shrink-0 items-center justify-center gap-1 rounded-token-lg text-tymeslot-700 hover:bg-tymeslot-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-turquoise-400"

  attr :view, :atom, required: true
  attr :date, :any, required: true
  attr :days, :list, required: true
  attr :today, :any, required: true
  attr :locale, :string, required: true
  attr :hidden_count, :integer, required: true
  attr :set_name, :string, default: nil
  attr :open_menu, :atom, default: nil
  attr :target, :any, required: true

  @spec phone_header(map()) :: Phoenix.LiveView.Rendered.t()
  def phone_header(assigns) do
    assigns =
      assign(assigns,
        control: @control,
        title: PeriodLabels.short_title(assigns.view, assigns.date, assigns.days, assigns.locale),
        compact_title:
          PeriodLabels.compact_title(assigns.view, assigns.date, assigns.days, assigns.locale)
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
      <button
        type="button"
        id="calendar-phone-title"
        class="inline-flex h-11 min-w-0 flex-1 items-center justify-center gap-0.5 rounded-token-lg px-1 text-token-sm font-semibold text-tymeslot-900 hover:bg-tymeslot-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-turquoise-400"
        aria-haspopup="dialog"
        aria-expanded={to_string(@open_menu == :date_sheet)}
        aria-label={dgettext("dashboard_calendar", "Choose a date, %{period}", period: @title)}
        phx-click="calendar:toggle_menu"
        phx-value-menu="date_sheet"
        phx-target={@target}
      >
        <%!-- One line: the dash form fits 360px in English, and a longer
             translation ends in an ellipsis; the aria-label has it in full. --%>
        <span class="min-w-0 truncate">{@compact_title}</span>
        <.icon name="hero-chevron-down-mini" class="h-4 w-4 shrink-0 text-tymeslot-500" />
      </button>
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
        id="calendar-phone-search"
        class={@control}
        aria-label={dgettext("dashboard_calendar_power", "Search and commands")}
        aria-haspopup="dialog"
        phx-click={JS.dispatch("calendar:command-open", to: "#calendar-canvas")}
      >
        <.icon name="hero-magnifying-glass" class="h-5 w-5" />
      </button>
      <%!-- Today's date on a calendar tile, as phone calendars show it: the
           word took the period's room at 360px. --%>
      <.tooltip text={dgettext("dashboard_calendar", "Today")}>
        <button
          type="button"
          id="calendar-phone-today"
          class={@control}
          aria-label={dgettext("dashboard_calendar", "Today")}
          phx-click={Navigation.js(@view, @today, from: {@view, @date})}
        >
          <span
            aria-hidden="true"
            class="inline-flex h-6 w-6 items-center justify-center rounded-token-md border-2 border-current text-token-xs font-bold tabular-nums"
          >
            {@today.day}
          </span>
        </button>
      </.tooltip>
      <%!-- Filters never hide silently: amber, with the count, while calendars are hidden. --%>
      <button
        type="button"
        id="calendar-phone-calendars"
        class={[
          @control,
          (@hidden_count > 0 or not is_nil(@set_name)) &&
            "border border-amber-300 bg-amber-50 px-2 text-amber-900"
        ]}
        aria-haspopup="dialog"
        aria-expanded={to_string(@open_menu == :calendars)}
        phx-click="calendar:toggle_menu"
        phx-value-menu="calendars"
        phx-target={@target}
      >
        <%!-- The set's name or the count replaces the icon, so the period keeps its room at 360px. --%>
        <.icon
          :if={@hidden_count == 0 and is_nil(@set_name)}
          name="hero-rectangle-stack"
          class="h-5 w-5"
        />
        <span class="sr-only">{dgettext("dashboard_calendar", "Calendars")}</span>
        <span :if={@set_name} class="max-w-24 truncate text-token-xs font-semibold">{@set_name}</span>
        <span :if={@hidden_count > 0 and is_nil(@set_name)} class="text-token-xs font-semibold">
          {dngettext("dashboard_calendar_views", "%{count} hidden", "%{count} hidden", @hidden_count)}
        </span>
      </button>
    </div>
    """
  end
end
