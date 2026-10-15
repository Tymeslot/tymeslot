defmodule TymeslotWeb.Themes.Shared.Blocks.MonthCalendar do
  @moduledoc """
  A month of days to pick the slot's date from: the month's name between
  previous and next month controls, the weekday headers (starting on
  `first_day`, the flow's `:week_start`, as the availability window is laid
  out) and one button per day of the window
  (`CalendarHelpers.get_calendar_days/7`, trailing weeks wholly in the next
  month trimmed).

  It is the behaviour of Quill's month grid without its look. A day is a
  button for the date fact (`data-fact="date"`, `data-value` the ISO date)
  sending `select_date`, with its full date as accessible name and
  `aria-pressed` on the chosen day; a past day, a day with nothing free and a
  day of a neighbouring month are disabled; today carries
  `aria-current="date"`. A padded day of a neighbouring month is no control
  for the date fact (no `data-fact`, no `data-value`): the markup contract
  has one control per value, and that day's control is in its own month.
  Days keep Quill's `data-testid="calendar-day"`. The month controls send
  `prev_month` and `next_month` and carry the period intents
  (`data-intent="earlier"`, `"later"`), disabled where `CalendarNavigation`
  says the booking window ends. Clicks go to `target`.

  Classes: `month-calendar` (`--loading`), `__nav`, `__nav-button`
  (`--prev`, `--next`), `__nav-icon`, `__title`, `__weekdays`, `__weekday`,
  `__days`, `__day` (`--selected`, `--today`, `--other-month`,
  `--unavailable`), `__notice`. The shared structure is
  `scheduling/shared/blocks/month-calendar.css`, on tokens only; a theme
  importing it sets `--month-calendar-gap` and `--month-calendar-day-size` to
  change them. `days` defaults to the flow's own, from the assigns given.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias TymeslotWeb.Live.Scheduling.{CalendarHelpers, CalendarNavigation}
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  attr :current_year, :integer, required: true
  attr :current_month, :integer, required: true
  attr :user_timezone, :string, required: true

  attr :first_day, :atom,
    required: true,
    values: [:monday, :sunday],
    doc: "the day the weeks start on, the flow's `:week_start`"

  attr :selected_date, :string, default: nil
  attr :availability_status, :atom, default: :not_loaded
  attr :booking_window_days, :integer, default: nil
  attr :organizer_profile, :any, default: nil
  attr :month_availability_map, :any, default: nil
  attr :meeting_type, :any, default: nil

  attr :days, :list,
    default: nil,
    doc: "the window's days; computed from the attributes above when nil"

  attr :target, :any, required: true
  attr :heading_tag, :string, default: "h3", values: ~w(h2 h3 h4)

  @spec month_calendar(map()) :: Phoenix.LiveView.Rendered.t()
  def month_calendar(assigns) do
    assigns = assign(assigns, :days, assigns.days || days(assigns))

    ~H"""
    <div
      class={["month-calendar", @availability_status == :loading && "month-calendar--loading"]}
      data-testid="month-calendar"
    >
      <div class="month-calendar__nav">
        <button
          type="button"
          class="month-calendar__nav-button month-calendar__nav-button--prev"
          data-testid="month-calendar-prev"
          data-intent="earlier"
          phx-click="prev_month"
          phx-target={@target}
          disabled={
            CalendarNavigation.prev_month_disabled?(@current_year, @current_month, @user_timezone)
          }
          aria-label={CalendarNavigation.month_nav_label(:prev)}
        >
          <.icon name="hero-chevron-left-mini" class="month-calendar__nav-icon" />
        </button>
        <.dynamic_tag tag_name={@heading_tag} class="month-calendar__title">
          {LocalizationHelpers.get_month_year_display(@current_year, @current_month)}
        </.dynamic_tag>
        <button
          type="button"
          class="month-calendar__nav-button month-calendar__nav-button--next"
          data-testid="month-calendar-next"
          data-intent="later"
          phx-click="next_month"
          phx-target={@target}
          disabled={
            next_disabled?(@current_year, @current_month, @user_timezone, @booking_window_days)
          }
          aria-label={CalendarNavigation.month_nav_label(:next)}
        >
          <.icon name="hero-chevron-right-mini" class="month-calendar__nav-icon" />
        </button>
      </div>
      <div class="month-calendar__weekdays" aria-hidden="true">
        <span
          :for={weekday <- LocalizationHelpers.weekday_headings(@first_day)}
          class="month-calendar__weekday"
        >
          {weekday}
        </span>
      </div>
      <div class="month-calendar__days">
        <button
          :for={day <- @days}
          type="button"
          class={[
            "month-calendar__day",
            @selected_date == day.date && "month-calendar__day--selected",
            day.today && "month-calendar__day--today",
            !day.current_month && "month-calendar__day--other-month",
            !bookable?(day) && "month-calendar__day--unavailable"
          ]}
          data-testid="calendar-day"
          data-fact={day.current_month && "date"}
          data-value={day.current_month && day.date}
          phx-click="select_date"
          phx-value-date={day.date}
          phx-target={@target}
          disabled={!bookable?(day)}
          aria-pressed={to_string(@selected_date == day.date)}
          aria-current={day.today && "date"}
          aria-label={LocalizationHelpers.format_full_date_label(day.date)}
        >
          <span aria-hidden="true">{day.day}</span>
        </button>
      </div>
      <p :if={@availability_status == :error} class="month-calendar__notice" role="status">
        {dgettext("booking", "Calendar is loading slowly")}
      </p>
    </div>
    """
  end

  @doc "The flow's days for the month shown, as `CalendarHelpers.get_calendar_days/7` builds them."
  @spec days(map()) :: [map()]
  def days(assigns) do
    CalendarHelpers.get_calendar_days(
      assigns.user_timezone,
      assigns.current_year,
      assigns.current_month,
      assigns.first_day,
      assigns.organizer_profile,
      assigns.month_availability_map,
      assigns.meeting_type
    )
  end

  defp bookable?(day) do
    Map.get(day, :available, false) == true and not Map.get(day, :past, false) and
      Map.get(day, :current_month, false) and not Map.get(day, :loading, false)
  end

  # No booking window known (no organiser resolved) bounds nothing.
  defp next_disabled?(year, month, timezone, days) when is_integer(days),
    do: CalendarNavigation.next_month_disabled?(year, month, timezone, days)

  defp next_disabled?(_year, _month, _timezone, _days), do: false
end
