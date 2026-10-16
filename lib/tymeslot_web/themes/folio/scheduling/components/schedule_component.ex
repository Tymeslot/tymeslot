defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.ScheduleComponent do
  @moduledoc """
  Folio's schedule step: the slim masthead, then one column: the step's
  title, the meeting's length and, for a group type, how many people it
  takes (`GroupSession.hint`), the spot a seat move is moving, the timezone
  picker, a month calendar and the chosen day's times (the shared
  `SlotList`, with a group type's seats), and the way on and back.

  The month buttons are labelled with the month they open, so they need no
  string of their own; they also carry `calendar-nav-button`, the class the
  visual harness's month navigation looks for.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Live.Scheduling.CalendarNavigation
  alias TymeslotWeb.Themes.Folio.Components.Masthead
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.Components.TimezonePicker
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  import TymeslotWeb.Components.FlagHelpers, only: [timezone_flag: 1]

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        prev_month_label: month_label(assigns.current_year, assigns.current_month, -1),
        next_month_label: month_label(assigns.current_year, assigns.current_month, 1)
      )

    ~H"""
    <section
      class="folio-card folio-card--schedule booker-card"
      data-locale={@locale}
      id={assigns[:moment] && "#{assigns[:moment]}-step"}
      data-moment={assigns[:moment]}
      data-moment-state={assigns[:moment_state]}
    >
      <Masthead.masthead
        variant={:slim}
        theme_tokens={@theme_tokens}
        organizer_profile={@organizer_profile}
        username_context={@username_context}
        meeting_label={Masthead.meeting_label(assigns)}
      />

      <div class="folio-card__body">
        <header class="folio-step-header">
          <h1 class="folio-title">{dgettext("booking", "Select a Date & Time")}</h1>
          <p class="folio-muted">
            {dgettext("booking", "Duration: %{duration}",
              duration: BookingText.duration_label(assigns)
            )}
          </p>
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
            <h2 class="folio-calendar__month calendar-month-label">
              {LocalizationHelpers.get_month_year_display(@current_year, @current_month)}
            </h2>
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
            <%= for day <- CalendarHelpers.get_calendar_days(@user_timezone, @current_year, @current_month, @week_start, @organizer_profile, @month_availability_map, @meeting_type) do %>
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
          heading_tag="h2"
          period_tag="h3"
        />

        <div class="folio-actions" data-testid="schedule-actions">
          <button
            :if={@entered_via_overview}
            type="button"
            class="folio-button folio-button--quiet"
            phx-click="back_step"
            phx-target={@myself}
            data-testid="back-step"
            data-intent="back"
          >
            <.icon name="hero-arrow-left-mini" class="folio-button__icon" />
            {dgettext("booking", "Back")}
          </button>
          <button
            type="button"
            class="folio-button folio-button--primary"
            phx-click="next_step"
            phx-target={@myself}
            data-testid="next-step"
            data-intent="continue"
            disabled={is_nil(@selected_date) or is_nil(@selected_time)}
          >
            {dgettext("booking", "Next")}
            <.icon name="hero-arrow-right-mini" class="folio-button__icon" />
          </button>
        </div>
      </div>
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
end
