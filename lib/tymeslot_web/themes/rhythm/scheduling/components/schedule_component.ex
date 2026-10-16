defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.ScheduleComponent do
  @moduledoc """
  Rhythm theme component for the schedule (date/time selection) step.
  Extracted from the monolithic RhythmSlidesComponent to improve separation of concerns.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Live.Scheduling.CalendarNavigation
  alias TymeslotWeb.Themes.Rhythm.Shared.OrganizerHeader
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
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
    <div class="scheduling-box booker-card" data-locale={@locale}>
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
                meeting_type={@meeting_type}
                selected_duration={@selected_duration}
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
                        fallback_icon="🌐"
                      />
                      <span class="timezone-text">{Timezones.format(@user_timezone)}</span>
                    </div>
                    <div class="timezone-arrow">▼</div>
                  </:trigger>
                </TimezonePicker.timezone_picker>
              </div>
            </div>

            <div class="schedule-grid">
              <div class="calendar-section calendar-section-wrapper">
                <div class="calendar-header">
                  <button
                    class="calendar-nav-button phx-click-loading:animate-pulse"
                    phx-click="prev_week"
                    phx-target={@myself}
                    data-intent="earlier"
                    phx-disable-with="..."
                    disabled={
                      CalendarNavigation.prev_week_disabled?(@current_week_start, @user_timezone)
                    }
                  >
                    ←
                  </button>
                  <h3 class="calendar-month-year">
                    {LocalizationHelpers.get_week_display(@current_week_start)}
                  </h3>
                  <div class="cluster cluster-xs">
                    <%= if @availability_status == :error do %>
                      <div class="calendar-error-inline">
                        <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                          />
                        </svg>
                        {dgettext("booking", "Service slow")}
                      </div>
                    <% end %>
                    <button
                      class="calendar-nav-button phx-click-loading:animate-pulse"
                      phx-click="next_week"
                      phx-target={@myself}
                      data-intent="later"
                      phx-disable-with="..."
                      disabled={
                        CalendarNavigation.next_week_disabled?(
                          @current_week_start,
                          @user_timezone,
                          @booking_window_days
                        )
                      }
                    >
                      →
                    </button>
                  </div>
                </div>

                <div class="calendar-grid">
                  <%= for day <- CalendarHelpers.get_week_days(@current_week_start, @organizer_profile, @month_availability_map, @user_timezone, @meeting_type) do %>
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
                :if={@entered_via_overview}
                class="prev-button"
                phx-click="back_step"
                phx-target={@myself}
                data-testid="back-step"
                data-intent="back"
              >
                ← {dgettext("booking", "Back")}
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
                {dgettext("booking", "Next")} →
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
