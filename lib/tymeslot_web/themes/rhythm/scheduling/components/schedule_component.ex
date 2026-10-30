defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.ScheduleComponent do
  @moduledoc """
  Rhythm theme component for the schedule (date/time selection) step.
  Extracted from the monolithic RhythmSlidesComponent to improve separation of concerns.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.CalendarDays
  alias TymeslotWeb.Live.Scheduling.CalendarNavigation
  alias TymeslotWeb.Themes.Rhythm.Shared.OrganizerHeader
  alias TymeslotWeb.Themes.Shared.ChosenLength
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.SessionList
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.Components.TimezonePicker
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  import TymeslotWeb.Components.FlagHelpers, only: [timezone_flag: 1]

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  # Selection is decided by the shared scheduling LiveView, which owns
  # `selected_date` and `selected_time` and passes them back down: a day click
  # re-selects rather than clears, a time click toggles.
  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="scheduling-box booker-card" data-locale={@locale} data-testid="booker-card">
      <div class="slide-container">
        <div class="slide active">
          <div class="slide-content schedule-slide">
            <GroupSession.seat_move_notice
              from={assigns[:reschedule_seat_from]}
              timezone={@user_timezone}
            />
            <div class="schedule-header">
              <OrganizerHeader.organizer_header_small
                organizer_profile={@organizer_profile}
                length_minutes={ChosenLength.minutes(assigns)}
                meeting_type={@meeting_type}
                selected_duration={@selected_duration}
                host_currency={@host_currency}
                show_price={!@is_rescheduling}
                locale={@locale}
              />
              <div class="timezone-selector-container">
                <%!-- Visual label only: it names no control (the trigger below carries
                     its own accessible name), so it must not be a <label> element. --%>
                <div class="timezone-label">{dgettext("booking", "Your timezone")}:</div>
                <TimezonePicker.timezone_picker
                  open={@timezone_dropdown_open}
                  search={@timezone_search}
                  target={@myself}
                >
                  <:trigger>
                    <div class="timezone-display">
                      <.timezone_flag
                        timezone={@user_timezone}
                        class="timezone-flag"
                        fallback_icon="hero-globe-alt"
                      />
                      <span class="timezone-text">{Timezones.format(@user_timezone)}</span>
                    </div>
                    <.icon name="hero-chevron-down" class="timezone-arrow" />
                  </:trigger>
                </TimezonePicker.timezone_picker>
              </div>
            </div>

            <SessionList.session_list
              sessions={assigns[:planned_sessions]}
              selected_date={@selected_date}
              timezone={@user_timezone}
              target={@myself}
            />

            <div :if={SessionList.show_calendar?(assigns[:planned_sessions])} class="schedule-grid">
              <div class="calendar-section calendar-section-wrapper">
                <div class="calendar-header">
                  <button
                    class="calendar-nav-button phx-click-loading:animate-pulse phx-click-loading:pointer-events-none"
                    phx-click="prev_week"
                    aria-label={dgettext("booking", "Previous week")}
                    phx-target={@myself}
                    data-intent="earlier"
                    disabled={
                      CalendarNavigation.prev_week_disabled?(@current_week_start, @user_timezone)
                    }
                  >
                    <.icon name="hero-arrow-left" class="inline-icon stroke-2" />
                  </button>
                  <h3 class="calendar-month-year">
                    {LocalizationHelpers.get_week_display(@current_week_start)}
                  </h3>
                  <div class="cluster cluster-xs">
                    <%= if @availability_status == :error do %>
                      <div class="calendar-error-inline">
                        <.icon name="hero-exclamation-triangle" />
                        {dgettext("booking", "Service slow")}
                      </div>
                    <% end %>
                    <button
                      class="calendar-nav-button phx-click-loading:animate-pulse phx-click-loading:pointer-events-none"
                      phx-click="next_week"
                      aria-label={dgettext("booking", "Next week")}
                      phx-target={@myself}
                      data-intent="later"
                      disabled={
                        CalendarNavigation.next_week_disabled?(
                          @current_week_start,
                          @user_timezone,
                          @booking_window_days
                        )
                      }
                    >
                      <.icon name="hero-arrow-right" class="inline-icon stroke-2" />
                    </button>
                  </div>
                </div>

                <div class="calendar-grid">
                  <%= for day <- CalendarDays.get_week_days(@current_week_start, @organizer_profile, @month_availability_map, @user_timezone, ChosenLength.meeting_type(assigns)) do %>
                    <button
                      class={[
                        "calendar-day",
                        @selected_date == day.date && "selected",
                        day.loading && "calendar-day--loading"
                      ]}
                      data-testid="calendar-day"
                      data-date={day.date}
                      data-fact="date"
                      data-value={day.date}
                      phx-click="select_date"
                      phx-value-date={day.date}
                      phx-target={@myself}
                      disabled={not day.available || day.loading}
                      aria-label={LocalizationHelpers.format_full_date_label(day.date)}
                      aria-current={day.today && "date"}
                    >
                      <div class="day-name" aria-hidden="true">{day.day_name}</div>
                      <div class="day-number" aria-hidden="true">{day.day_number}</div>
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
            </div>

            <div class="slide-actions horizontal" data-testid="schedule-actions">
              <button
                :if={@entered_via_overview or ChosenLength.choose?(assigns)}
                class="prev-button"
                phx-click="back_step"
                phx-target={@myself}
                data-testid="back-step"
                data-intent="back"
              >
                <.icon name="hero-arrow-left" class="inline-icon" />
                {dgettext("booking", "Back")}
              </button>
              <button
                class={
                  if @selected_date && @selected_time, do: "next-button", else: "next-button disabled"
                }
                phx-click="next_step"
                phx-target={@myself}
                data-testid="next-step"
                data-intent="continue"
                disabled={is_nil(@selected_date) or is_nil(@selected_time)}
              >
                {dgettext("booking", "Next")}
                <.icon name="hero-arrow-right" class="inline-icon" />
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
