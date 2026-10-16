defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.WhenMoment do
  @moduledoc """
  The time, which opens below the ways to work once a meeting type is
  chosen: a heading, how far ahead it can be booked (the length is in the
  chosen entry and the summary bar, so it is not said a third time) and,
  for a group type, how many people it takes (`GroupSession.hint`), the
  spot a seat move is moving, the timezone picker, Folio's month calendar
  (each day a button for the date fact) and the chosen day's times (the
  shared `SlotList`, a button per time for the time fact, with a group
  type's seats). Picking a time opens the details below by itself; there is
  no Next.

  The month buttons are labelled with the month they open, so they need no
  string of their own; they carry `calendar-nav-button` and the period
  intents (`data-intent="earlier"`, `"later"`), and the days `calendar-day`,
  as the visual harness and the suites look for them.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Live.Scheduling.CalendarNavigation
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.Components.TimezonePicker
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  import TymeslotWeb.Components.FlagHelpers, only: [timezone_flag: 1]

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    days =
      CalendarHelpers.get_calendar_days(
        assigns.user_timezone,
        assigns.current_year,
        assigns.current_month,
        assigns.week_start,
        assigns.organizer_profile,
        assigns.month_availability_map,
        assigns.meeting_type
      )

    assigns =
      assign(assigns,
        days: days,
        month_notice: month_notice(days, assigns),
        prev_month_label: month_label(assigns.current_year, assigns.current_month, -1),
        next_month_label: month_label(assigns.current_year, assigns.current_month, 1)
      )

    ~H"""
    <section
      id={"#{@moment}-step"}
      class="folio-section folio-when booker-card"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <header class="folio-section__header">
        <JourneyComponents.moment_heading
          moment={@moment}
          moment_state={@moment_state}
          focus={assigns[:journey_focus]}
          class="folio-section__title"
        >
          {dpgettext("booking_voice", "folio", "When suits you?")}
        </JourneyComponents.moment_heading>
        <p :if={@booking_window_days} class="folio-muted">
          {dgettext("booking", "Bookings available up to %{advance}",
            advance: LocalizationHelpers.format_advance_booking_days(@booking_window_days)
          )}
        </p>
        <GroupSession.hint meeting_type={@meeting_type} />
      </header>

      <GroupSession.seat_move_notice
        from={assigns[:reschedule_seat_from]}
        timezone={@user_timezone}
      />

      <div class="folio-timezone">
        <%!-- Visual label only: the trigger carries its own accessible name. --%>
        <span class="folio-eyebrow" aria-hidden="true">{dgettext("booking", "Your timezone")}</span>
        <TimezonePicker.timezone_picker
          open={@timezone_dropdown_open}
          search={@timezone_search}
          target={@myself}
        >
          <:trigger>
            <span class="folio-timezone__current">
              <.timezone_flag
                timezone={@user_timezone}
                class="folio-timezone__flag"
                fallback_icon="🌐"
              />
              <span class="folio-timezone__name">{Timezones.format(@user_timezone)}</span>
            </span>
            <.icon name="hero-chevron-down-mini" class="folio-timezone__chevron" />
          </:trigger>
        </TimezonePicker.timezone_picker>
      </div>

      <div class="folio-calendar">
        <div class="folio-calendar__header">
          <button
            type="button"
            class="folio-calendar__nav calendar-nav-button"
            phx-click="prev_month"
            data-intent="earlier"
            phx-target={@myself}
            aria-label={@prev_month_label}
            disabled={
              CalendarNavigation.prev_month_disabled?(
                @current_year,
                @current_month,
                @user_timezone
              )
            }
          >
            <.icon name="hero-chevron-left-mini" class="folio-calendar__nav-icon" />
          </button>
          <h3 class="folio-calendar__month calendar-month-label">
            {LocalizationHelpers.get_month_year_display(@current_year, @current_month)}
          </h3>
          <button
            type="button"
            class="folio-calendar__nav calendar-nav-button"
            phx-click="next_month"
            data-intent="later"
            phx-target={@myself}
            aria-label={@next_month_label}
            disabled={
              CalendarNavigation.next_month_disabled?(
                @current_year,
                @current_month,
                @user_timezone,
                @booking_window_days
              )
            }
          >
            <.icon name="hero-chevron-right-mini" class="folio-calendar__nav-icon" />
          </button>
        </div>

        <p :if={@availability_status == :error} class="folio-calendar__notice" role="status">
          {dgettext("booking", "Calendar is loading slowly")}
        </p>

        <div
          :if={@month_notice}
          class="folio-calendar__notice"
          role="status"
          data-testid="folio-month-empty"
        >
          <%= if @month_notice == :elsewhere do %>
            <p>{dpgettext("booking_voice", "folio", "I'm fully booked this month.")}</p>
            <button
              type="button"
              class="folio-button folio-button--quiet"
              phx-click="first_available_week"
              phx-target={@myself}
              data-testid="folio-next-free-day"
            >
              {dpgettext("booking_voice", "folio", "Show my next free day")}
            </button>
          <% else %>
            <p>{dpgettext("booking_voice", "folio", "I have no free times at the moment.")}</p>
          <% end %>
        </div>

        <div class="folio-calendar__weekdays" aria-hidden="true">
          <span
            :for={day <- LocalizationHelpers.weekday_headings(@week_start)}
            class="folio-calendar__weekday"
          >
            {day}
          </span>
        </div>

        <div class={[
          "folio-calendar__grid",
          @availability_status == :loading && "folio-calendar__grid--loading"
        ]}>
          <%= for day <- @days do %>
            <% bookable = day[:available] && !day[:past] && day[:current_month] %>
            <button
              type="button"
              class={[
                "calendar-day",
                bookable && "calendar-day--available",
                @selected_date == day[:date] && "calendar-day--selected",
                !day[:current_month] && "calendar-day--other-month",
                day[:today] && "calendar-day--today",
                Map.get(day, :loading, false) && "calendar-day--loading"
              ]}
              data-testid="calendar-day"
              data-date={day[:date]}
              data-fact={day[:current_month] && "date"}
              data-value={day[:current_month] && day[:date]}
              phx-click="select_date"
              phx-value-date={day[:date]}
              phx-target={@myself}
              disabled={!bookable || Map.get(day, :loading, false)}
              aria-label={LocalizationHelpers.format_full_date_label(day[:date])}
              aria-current={day[:today] && "date"}
              aria-pressed={to_string(@selected_date == day[:date])}
            >
              <span class="calendar-day__number" aria-hidden="true">{day[:day]}</span>
            </button>
          <% end %>
        </div>
      </div>

      <SlotList.slot_list
        selected_date={@selected_date}
        selected_time={@selected_time}
        available_slots={@available_slots}
        loading_slots={@loading_slots}
        calendar_error={@calendar_error}
        slot_interval_minutes={@slot_interval_minutes}
        duration_minutes={@duration_minutes}
        expanded_hour={@expanded_hour}
        meeting_type={@meeting_type}
        target={@myself}
        heading_tag="h3"
        period_tag="h4"
      />
    </section>
    """
  end

  # The name of the month `delta` months from the one on screen, which labels
  # the button that opens it.
  defp month_label(year, month, delta) when is_integer(year) and is_integer(month) do
    index = year * 12 + (month - 1) + delta
    LocalizationHelpers.get_month_year_display(div(index, 12), rem(index, 12) + 1)
  end

  defp month_label(_year, _month, _delta), do: nil

  # What a month with no free day says: nothing while it loads or while a
  # day of its own can be picked; `:elsewhere` when the page landed on a
  # free day in another month (the button goes there); `:none_free` when it
  # landed on none, so no month in the window has one.
  defp month_notice(days, assigns) do
    cond do
      not month_empty?(days, assigns.availability_status) -> nil
      landed_elsewhere?(assigns) -> :elsewhere
      true -> :none_free
    end
  end

  defp month_empty?(days, status) when status in [:loaded, :error] do
    own = Enum.filter(days, & &1[:current_month])
    own != [] and not Enum.any?(own, &(&1[:available] && !&1[:past]))
  end

  defp month_empty?(_days, _status), do: false

  # The page landed the visitor on a free day (`landing_week/1` is set only
  # then) in another month than the one on show; `calendar_landing` keeps
  # the landing's month.
  defp landed_elsewhere?(
         %{calendar_landing: %{current_year: year, current_month: month}} = assigns
       ),
       do:
         CalendarHelpers.landing_week(assigns) != nil and
           {year, month} != {assigns.current_year, assigns.current_month}

  defp landed_elsewhere?(_assigns), do: false
end
