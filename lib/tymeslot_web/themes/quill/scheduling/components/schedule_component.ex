defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent do
  @moduledoc """
  Quill theme component for the schedule/calendar step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Live.Scheduling.CalendarNavigation
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
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
      <svg
        class="animate-spin h-4 w-4 text-white opacity-60"
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
      >
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path
          class="opacity-75"
          fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
        />
      </svg>
    <% end %>
    """
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, :navigable_steps, Runtime.navigable_steps(assigns))

    ~H"""
    <div class="container quill-container flex-1" data-locale={@locale}>
      <.page_layout
        show_steps={true}
        navigable_steps={@navigable_steps}
        current_step={2}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="stack">
          <div class="schedule-content-area flex-1 flex items-start justify-center">
            <div class="w-full min-h-0">
              <.glass_morphism_card class="booker-card calendar-card">
                <div class="schedule-card-body min-h-0">
                  <%!-- Header: title + compact timezone trigger --%>
                  <div class="schedule-card-header">
                    <div class="flex-1 min-w-0">
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

                  <div class="calendar-slots-container">
                    <div class="flex-1 calendar-section">
                      <%!-- Weekly view: shown on small screens --%>
                      <div class="calendar-weekly">
                        <div class="weekly-nav-row">
                          <button
                            phx-click="prev_week"
                            phx-target={@myself}
                            phx-disable-with="..."
                            disabled={
                              CalendarNavigation.prev_week_disabled?(
                                @current_week_start,
                                @user_timezone
                              )
                            }
                            class="calendar-nav-button p-1 rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse"
                          >
                            ←
                          </button>
                          <div class="weekly-nav-label">
                            <div class="text-xs font-semibold text-white">
                              {LocalizationHelpers.get_week_display(@current_week_start)}
                            </div>
                            <.loading_spinner show={@availability_status == :loading} />
                          </div>
                          <button
                            phx-click="next_week"
                            phx-target={@myself}
                            phx-disable-with="..."
                            disabled={
                              CalendarNavigation.next_week_disabled?(
                                @current_week_start,
                                @user_timezone,
                                @booking_window_days
                              )
                            }
                            class="calendar-nav-button p-1 rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse"
                          >
                            →
                          </button>
                        </div>
                        <div class="week-day-strip">
                          <%= for day <- CalendarHelpers.get_week_days(@current_week_start, @organizer_profile, @month_availability_map, @user_timezone, @meeting_type) do %>
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
                                <svg
                                  class="w-3 h-3"
                                  fill="none"
                                  stroke="currentColor"
                                  viewBox="0 0 24 24"
                                >
                                  <path
                                    stroke-linecap="round"
                                    stroke-linejoin="round"
                                    stroke-width="2"
                                    d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                                  />
                                </svg>
                                {dgettext("booking", "Calendar is loading slowly")}
                              </div>
                            <% end %>
                            <button
                              phx-click="prev_month"
                              phx-target={@myself}
                              data-intent="earlier"
                              phx-disable-with="..."
                              disabled={
                                CalendarNavigation.prev_month_disabled?(
                                  @current_year,
                                  @current_month,
                                  @user_timezone
                                )
                              }
                              class="calendar-nav-button rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse"
                            >
                              ←
                            </button>
                            <div class="calendar-month-label font-semibold text-white">
                              {LocalizationHelpers.get_month_year_display(
                                @current_year,
                                @current_month
                              )}
                            </div>
                            <button
                              phx-click="next_month"
                              phx-target={@myself}
                              data-intent="later"
                              phx-disable-with="..."
                              disabled={
                                CalendarNavigation.next_month_disabled?(
                                  @current_year,
                                  @current_month,
                                  @user_timezone,
                                  @booking_window_days
                                )
                              }
                              class="calendar-nav-button rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse"
                            >
                              →
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
                            <%= for day <- CalendarHelpers.get_calendar_days(@user_timezone, @current_year, @current_month, @week_start, @organizer_profile, @month_availability_map, @meeting_type) do %>
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
                            <svg
                              class="w-12 h-12 mx-auto mb-2 text-tymeslot-400"
                              fill="none"
                              stroke="currentColor"
                              viewBox="0 0 24 24"
                              aria-hidden="true"
                            >
                              <path
                                stroke-linecap="round"
                                stroke-linejoin="round"
                                stroke-width="2"
                                d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"
                              >
                              </path>
                            </svg>
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

                  <div class="schedule-actions shrink-0" data-testid="schedule-actions">
                    <.action_button
                      :if={@entered_via_overview}
                      type="button"
                      phx-click="back_step"
                      phx-target={@myself}
                      data-testid="back-step"
                      data-intent="back"
                      variant={:secondary}
                      class="flex-1"
                    >
                      ← {dgettext("booking", "Back")}
                    </.action_button>

                    <.action_button
                      phx-click="next_step"
                      phx-target={@myself}
                      data-testid="next-step"
                      data-intent="continue"
                      disabled={!(@selected_date && @selected_time)}
                      class="flex-1"
                    >
                      {dgettext("booking", "Next Step")} →
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
          <svg class="timezone-label-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
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
              <.timezone_flag timezone={@user_timezone} class="timezone-flag" fallback_icon="🌐" />
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
              <svg
                class={["timezone-chevron", @timezone_dropdown_open && "open"]}
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 9l-7 7-7-7"
                />
              </svg>
            </div>
          </div>
        </:trigger>
      </TimezonePicker.timezone_picker>
    </div>
    """
  end
end
