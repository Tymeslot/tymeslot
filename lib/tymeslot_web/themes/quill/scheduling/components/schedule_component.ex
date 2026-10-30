defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent do
  @moduledoc """
  Quill theme component for the schedule/calendar step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.CalendarDays
  alias TymeslotWeb.Live.Scheduling.CalendarNavigation
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.ChosenLength
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.MeetingPrice
  alias TymeslotWeb.Themes.Shared.Components.SessionList
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.Components.TimezonePicker
  alias TymeslotWeb.Themes.Shared.Journey.Runtime
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents
  alias TymeslotWeb.Themes.Shared.TimezoneHelpers

  use TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Components.FlagHelpers, only: [timezone_flag: 1]

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  # ========== CALENDAR COMPONENTS ==========

  attr :day, :map, required: true
  attr :selected, :boolean, default: false
  attr :available, :boolean, default: true
  attr :current_month, :boolean, default: true
  attr :loading, :boolean, default: false
  attr :rest, :global

  defp calendar_day(assigns) do
    ~H"""
    <button
      class={[
        "calendar-day",
        @selected && "calendar-day--selected",
        !@available && "calendar-day--unavailable",
        !@current_month && "calendar-day--other-month",
        @day.is_today && "calendar-day--today",
        Map.get(@day, :past, false) && "calendar-day--past",
        @loading && "calendar-day--loading"
      ]}
      data-testid="calendar-day"
      data-date={@day[:date] || @day["date"]}
      data-fact={@current_month && "date"}
      data-value={@current_month && (@day[:date] || @day["date"])}
      disabled={!@available || !@current_month || @loading}
      aria-label={LocalizationHelpers.format_full_date_label(@day[:date] || @day["date"])}
      aria-current={@day.is_today && "date"}
      {@rest}
    >
      <span class="calendar-day__number" aria-hidden="true">{@day.day}</span>
    </button>
    """
  end

  # ========== PRIVATE HELPERS ==========

  attr :show, :boolean, required: true

  defp loading_spinner(assigns) do
    ~H"""
    <%= if @show do %>
      <.spinner class="spinner--sm text-white opacity-60" />
    <% end %>
    """
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        navigable_steps: Runtime.navigable_steps(assigns),
        step_numbers: Runtime.step_numbers(assigns)
      )

    ~H"""
    <div class="container quill-container flex-1" data-locale={@locale}>
      <.page_layout
        show_steps={true}
        navigable_steps={@navigable_steps}
        step_numbers={@step_numbers}
        current_step={2}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="stack">
          <div class="schedule-content-area flex-1 flex items-start justify-center">
            <div class="w-full min-h-0">
              <.glass_morphism_card class="booker-card calendar-card" data-testid="booker-card">
                <div class="schedule-card-body min-h-0">
                  <%!-- Header: title + compact timezone trigger --%>
                  <div class="schedule-card-header">
                    <div class="schedule-title-area">
                      <h1 class="section-header schedule-title">
                        {dgettext("booking", "Select a Date & Time")}
                      </h1>

                      <%= if @organizer_profile do %>
                        <p class="schedule-advance-notice text-glass-primary">
                          {dgettext("booking", "Bookings available up to %{advance}",
                            advance:
                              LocalizationHelpers.format_advance_booking_days(@booking_window_days)
                          )}
                        </p>
                      <% end %>

                      <p class="schedule-duration-label text-glass-primary">
                        {dgettext("booking", "Duration: %{duration}",
                          duration: BookingText.duration_label(assigns)
                        )}
                      </p>

                      <GroupSession.hint meeting_type={@meeting_type} class="mt-2" />
                      <MeetingPrice.hint
                        :if={!@is_rescheduling}
                        meeting_type={@meeting_type}
                        currency={@host_currency}
                        locale={@locale}
                        class="mt-2"
                      />

                      <GroupSession.seat_move_notice
                        from={assigns[:reschedule_seat_from]}
                        timezone={@user_timezone}
                        class="mt-2"
                      />
                    </div>

                    <div class="schedule-timezone-area">
                      <.timezone_selector
                        user_timezone={@user_timezone}
                        timezone_search={@timezone_search}
                        timezone_dropdown_open={@timezone_dropdown_open}
                        target={@myself}
                        locale={@locale}
                      />
                    </div>
                  </div>

                  <%!-- The card's one scrolling region, between the pinned header and
                       actions: a fixed-date type's dates scroll with the calendar
                       rather than squeezing it. --%>
                  <div class="schedule-scroll">
                    <SessionList.session_list
                      sessions={assigns[:planned_sessions]}
                      selected_date={@selected_date}
                      timezone={@user_timezone}
                      target={@myself}
                    />

                    <div
                      :if={SessionList.show_calendar?(assigns[:planned_sessions])}
                      class="calendar-slots-container"
                    >
                      <div class="flex-1 calendar-section">
                        <%!-- Weekly view: shown on small screens --%>
                        <div class="calendar-weekly">
                          <div class="weekly-nav-row">
                            <button
                              phx-click="prev_week"
                              aria-label={dgettext("booking", "Previous week")}
                              phx-target={@myself}
                              disabled={
                                CalendarNavigation.prev_week_disabled?(
                                  @current_week_start,
                                  @user_timezone
                                )
                              }
                              class="calendar-nav-button p-1 rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse phx-click-loading:pointer-events-none"
                            >
                              <.icon name="hero-arrow-left" class="inline-icon stroke-2" />
                            </button>
                            <div class="weekly-nav-label">
                              <div class="text-xs font-semibold text-white">
                                {LocalizationHelpers.get_week_display(@current_week_start)}
                              </div>
                              <.loading_spinner show={@availability_status == :loading} />
                            </div>
                            <button
                              phx-click="next_week"
                              aria-label={dgettext("booking", "Next week")}
                              phx-target={@myself}
                              disabled={
                                CalendarNavigation.next_week_disabled?(
                                  @current_week_start,
                                  @user_timezone,
                                  @booking_window_days
                                )
                              }
                              class="calendar-nav-button p-1 rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse phx-click-loading:pointer-events-none"
                            >
                              <.icon name="hero-arrow-right" class="inline-icon stroke-2" />
                            </button>
                          </div>
                          <div class="week-day-strip">
                            <%= for day <- CalendarDays.get_week_days(@current_week_start, @organizer_profile, @month_availability_map, @user_timezone, ChosenLength.meeting_type(assigns)) do %>
                              <button
                                class={[
                                  "week-day-cell",
                                  @selected_date == day.date && "selected",
                                  day.loading && "loading"
                                ]}
                                phx-click="select_date"
                                phx-value-date={day.date}
                                phx-target={@myself}
                                disabled={not day.available || day.loading}
                                aria-label={LocalizationHelpers.format_full_date_label(day.date)}
                                aria-current={day.today && "date"}
                              >
                                <span class="week-day-name" aria-hidden="true">{day.day_name}</span>
                                <span class="week-day-number" aria-hidden="true">{day.day_number}</span>
                              </button>
                            <% end %>
                          </div>
                        </div>

                        <%!-- Monthly view: shown on larger screens --%>
                        <div class="calendar-monthly">
                          <div class="calendar-month-header">
                            <h2 class="calendar-month-title font-bold text-glass-primary">
                              {dgettext("booking", "Select a Date")}
                              <.loading_spinner show={@availability_status == :loading} />
                            </h2>
                            <div class="calendar-nav-cluster">
                              <%= if @availability_status == :error do %>
                                <div class="text-xs text-amber-300 bg-amber-900/40 px-2 py-1 rounded border border-amber-700/50 flex items-center gap-1">
                                  <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
                                  {dgettext("booking", "Calendar is loading slowly")}
                                </div>
                              <% end %>
                              <button
                                phx-click="prev_month"
                                aria-label={dgettext("booking", "Previous month")}
                                phx-target={@myself}
                                data-intent="earlier"
                                disabled={
                                  CalendarNavigation.prev_month_disabled?(
                                    @current_year,
                                    @current_month,
                                    @user_timezone
                                  )
                                }
                                class="calendar-nav-button rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse phx-click-loading:pointer-events-none"
                              >
                                <.icon name="hero-arrow-left" class="inline-icon stroke-2" />
                              </button>
                              <div class="calendar-month-label font-semibold text-white">
                                {LocalizationHelpers.get_month_year_display(
                                  @current_year,
                                  @current_month
                                )}
                              </div>
                              <button
                                phx-click="next_month"
                                aria-label={dgettext("booking", "Next month")}
                                phx-target={@myself}
                                data-intent="later"
                                disabled={
                                  CalendarNavigation.next_month_disabled?(
                                    @current_year,
                                    @current_month,
                                    @user_timezone,
                                    @booking_window_days
                                  )
                                }
                                class="calendar-nav-button rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse phx-click-loading:pointer-events-none"
                              >
                                <.icon name="hero-arrow-right" class="inline-icon stroke-2" />
                              </button>
                            </div>
                          </div>
                          <div class="calendar-grid-container flex-1">
                            <div class="calendar-month-grid grid grid-cols-7 gap-0.5 text-center mb-1">
                              <div
                                :for={day <- LocalizationHelpers.weekday_headings(@week_start)}
                                class="calendar-weekday text-xs font-medium"
                              >
                                {day}
                              </div>
                            </div>
                            <div class="calendar-month-grid grid grid-cols-7 gap-0.5">
                              <%= for day <- CalendarDays.get_calendar_days(@user_timezone, @current_year, @current_month, @week_start, @organizer_profile, @month_availability_map, ChosenLength.meeting_type(assigns)) do %>
                                <.calendar_day
                                  phx-click="select_date"
                                  phx-target={@myself}
                                  phx-value-date={day[:date]}
                                  day={Map.put(day, :is_today, day[:today])}
                                  selected={@selected_date == day[:date]}
                                  available={day[:available] && !day[:past]}
                                  current_month={day[:current_month]}
                                  loading={Map.get(day, :loading, false)}
                                />
                              <% end %>
                            </div>
                          </div>
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
                      >
                        <:loading>
                          <div class="h-full flex items-center justify-center">
                            <.spinner />
                            <span class="ml-3 text-white">
                              {dgettext("booking", "Loading available times...")}
                            </span>
                          </div>
                        </:loading>
                        <:error :let={message}>
                          <.info_box variant={:warning}>
                            {message}
                          </.info_box>
                        </:error>
                        <:empty>
                          <%!-- Drawn in Quill's own light-on-glass colours, so it
                             stays local rather than using the dashboard's empty
                             state. --%>
                          <div class="h-full flex items-center justify-center">
                            <div class="text-center p-4">
                              <.icon
                                name="hero-no-symbol"
                                class="w-12 h-12 mx-auto mb-2 text-tymeslot-400"
                              />
                              <p class="text-sm font-medium" style="color: rgba(255,255,255,0.8);">
                                {dgettext("booking", "This date is fully booked")}
                              </p>
                              <p class="text-xs mt-1" style="color: rgba(255,255,255,0.6);">
                                {dgettext("booking", "Please select another date")}
                              </p>
                            </div>
                          </div>
                        </:empty>
                      </SlotList.slot_list>
                    </div>
                  </div>

                  <div class="schedule-actions shrink-0" data-testid="schedule-actions">
                    <.action_button
                      :if={@entered_via_overview or ChosenLength.choose?(assigns)}
                      type="button"
                      phx-click="back_step"
                      phx-target={@myself}
                      data-testid="back-step"
                      data-intent="back"
                      variant={:secondary}
                      class="flex-1 gap-2"
                    >
                      <.icon name="hero-arrow-left" class="inline-icon" />
                      {dgettext("booking", "Back")}
                    </.action_button>

                    <.action_button
                      phx-click="next_step"
                      phx-target={@myself}
                      data-testid="next-step"
                      data-intent="continue"
                      disabled={!(@selected_date && @selected_time)}
                      class="flex-1 gap-2"
                    >
                      {dgettext("booking", "Next Step")}
                      <.icon name="hero-arrow-right" class="inline-icon" />
                    </.action_button>
                  </div>
                </div>
              </.glass_morphism_card>
            </div>
          </div>
        </div>
      </.page_layout>
    </div>
    """
  end

  attr :user_timezone, :string, required: true
  attr :timezone_search, :string, required: true
  attr :timezone_dropdown_open, :boolean, required: true
  attr :target, :any, required: true
  attr :locale, :string, required: true

  defp timezone_selector(assigns) do
    ~H"""
    <div class="relative" data-locale={@locale}>
      <%!-- Visual label only: it names no control (the trigger below carries its
           own accessible name), so it must not be a <label> element. --%>
      <div class="timezone-label">
        <div class="timezone-label-content">
          <.icon name="hero-clock" class="timezone-label-icon" />
          {dgettext("booking", "Your timezone")}
        </div>
      </div>

      <TimezonePicker.timezone_picker
        open={@timezone_dropdown_open}
        search={@timezone_search}
        target={@target}
      >
        <:trigger>
          <div class="timezone-trigger-row">
            <div class="timezone-trigger-info">
              <.timezone_flag
                timezone={@user_timezone}
                class="timezone-flag"
                fallback_icon="hero-globe-alt"
              />
              <div class="timezone-trigger-text">
                <div class="timezone-name">
                  {Timezones.format(@user_timezone)}
                </div>
                <div class="timezone-time-display timezone-time-inline">
                  {dgettext("booking", "%{time} local time",
                    time: TimezoneHelpers.format_local_time(@user_timezone)
                  )}
                </div>
              </div>
            </div>
            <div class="timezone-meta">
              <div class="timezone-offset-badge">
                {Timezones.utc_offset(@user_timezone)}
              </div>
              <.icon
                name="hero-chevron-down"
                class={["timezone-chevron", @timezone_dropdown_open && "open"]}
              />
            </div>
          </div>
        </:trigger>
      </TimezonePicker.timezone_picker>
    </div>
    """
  end
end
