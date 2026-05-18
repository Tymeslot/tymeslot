defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent do
  @moduledoc """
  Quill theme component for the schedule/calendar step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.DateTimeUtils.Duration
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Live.Scheduling.CalendarNavigation
  alias TymeslotWeb.Themes.Quill.Scheduling.Components.Schedule.Panels
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  import TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # Filter out reserved assigns that can't be set directly
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_date", %{"date" => date}, socket) do
    send(self(), {:step_event, :schedule, :select_date, date})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_time", %{"time" => time}, socket) do
    send(self(), {:step_event, :schedule, :select_time, time})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change_timezone", %{"timezone" => timezone}, socket) do
    send(self(), {:step_event, :schedule, :change_timezone, timezone})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("search_timezone", params, socket) do
    send(self(), {:step_event, :schedule, :search_timezone, params})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_timezone_dropdown", _params, socket) do
    send(self(), {:step_event, :schedule, :toggle_timezone_dropdown, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("close_timezone_dropdown", _params, socket) do
    send(self(), {:step_event, :schedule, :close_timezone_dropdown, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("prev_month", _params, socket) do
    send(self(), {:step_event, :schedule, :prev_month, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("next_month", _params, socket) do
    send(self(), {:step_event, :schedule, :next_month, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("prev_week", _params, socket) do
    send(self(), {:step_event, :schedule, :prev_week, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("next_week", _params, socket) do
    send(self(), {:step_event, :schedule, :next_week, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("back_step", _params, socket) do
    send(self(), {:step_event, :schedule, :back_step, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("next_step", _params, socket) do
    send(self(), {:step_event, :schedule, :next_step, nil})
    {:noreply, socket}
  end

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
      disabled={!@available || !@current_month || @loading}
      {@rest}
    >
      <span class="calendar-day__number">{@day.day}</span>
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
    ~H"""
    <div class="container flex-1" data-locale={@locale}>
      <.page_layout
        show_steps={true}
        current_step={2}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="stack">
          <div class="schedule-content-area flex-1 flex items-start justify-center">
            <div class="w-full max-w-5xl min-h-0">
              <.glass_morphism_card class="calendar-card">
                <div class="schedule-card-body min-h-0">
                  <%!-- Header: title + compact timezone trigger --%>
                  <div class="schedule-card-header">
                    <div class="flex-1 min-w-0">
                      <.section_header
                        level={2}
                        class="mb-1"
                        title_class="section-header schedule-title"
                      >
                        {gettext("Select a Date & Time")}
                      </.section_header>

                      <%= if @organizer_profile do %>
                        <p class="schedule-advance-notice text-glass-primary">
                          {gettext("Bookings available up to %{advance}", advance: Panels.format_advance_booking_days(
                            @organizer_profile.advance_booking_days
                          ))}
                        </p>
                      <% end %>

                      <p class="schedule-duration-label text-glass-primary">
                        <%= if @meeting_type do %>
                          {gettext("Duration: %{duration}", duration: LocalizationHelpers.format_duration(@meeting_type.duration_minutes))}
                        <% else %>
                          {gettext("Duration: %{duration}", duration: Duration.format(@duration))}
                        <% end %>
                      </p>
                    </div>

                    <div class="schedule-timezone-area">
                      <Panels.timezone_selector
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
                            disabled={CalendarNavigation.prev_week_disabled?(@current_week_start, @user_timezone)}
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
                            disabled={CalendarNavigation.next_week_disabled?(@current_week_start, @user_timezone, @organizer_profile.advance_booking_days)}
                            class="calendar-nav-button p-1 rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse"
                          >
                            →
                          </button>
                        </div>
                        <div class="week-day-strip">
                          <%= for day <- CalendarHelpers.get_week_days(@current_week_start, @organizer_profile, @month_availability_map, @user_timezone) do %>
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
                            >
                              <span class="week-day-name">{day.day_name}</span>
                              <span class="week-day-number">{day.day_number}</span>
                            </button>
                          <% end %>
                        </div>
                      </div>

                      <%!-- Monthly view: shown on larger screens --%>
                      <div class="calendar-monthly">
                        <div class="calendar-month-header">
                          <h2 class="calendar-month-title font-bold text-glass-primary">
                            {gettext("Select a Date")}
                            <.loading_spinner show={@availability_status == :loading} />
                          </h2>
                          <div class="calendar-nav-cluster">
                            <%= if @availability_status in [:error, :timeout] do %>
                              <div class="text-xs text-amber-300 bg-amber-900/40 px-2 py-1 rounded border border-amber-700/50 flex items-center gap-1">
                                <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                                </svg>
                                {gettext("Calendar is loading slowly")}
                              </div>
                            <% end %>
                            <button
                              phx-click="prev_month"
                              phx-target={@myself}
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
                              {LocalizationHelpers.get_month_year_display(@current_year, @current_month)}
                            </div>
                            <button
                              phx-click="next_month"
                              phx-target={@myself}
                              phx-disable-with="..."
                              disabled={
                                  CalendarNavigation.next_month_disabled?(
                                    @current_year,
                                    @current_month,
                                    @user_timezone,
                                    @organizer_profile.advance_booking_days
                                  )
                              }
                              class="calendar-nav-button rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse"
                            >
                              →
                            </button>
                          </div>
                        </div>
                        <div class="calendar-grid-container flex-1">
                          <div class="grid grid-cols-7 gap-0.5 text-center mb-1">
                            <div
                              :for={day <- [gettext("Sun"), gettext("Mon"), gettext("Tue"), gettext("Wed"), gettext("Thu"), gettext("Fri"), gettext("Sat")]}
                              class="calendar-weekday text-xs font-medium"
                            >
                              {String.slice(day, 0, 3)}
                            </div>
                          </div>
                          <div class="grid grid-cols-7 gap-0.5">
                            <%= for day <- CalendarHelpers.get_calendar_days(@user_timezone, @current_year, @current_month, @organizer_profile, @month_availability_map) do %>
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

                    <Panels.time_slots_panel
                      selected_date={@selected_date}
                      loading_slots={@loading_slots}
                      calendar_error={@calendar_error}
                      available_slots={@available_slots}
                      selected_time={@selected_time}
                      target={@myself}
                    />
                  </div>

                  <div class="schedule-actions flex-shrink-0">
                    <.action_button
                      type="button"
                      phx-click="back_step"
                      phx-target={@myself}
                      data-testid="back-step"
                      variant={:secondary}
                      class="flex-1"
                    >
                      ← {gettext("back")}
                    </.action_button>

                    <.action_button
                      phx-click="next_step"
                      phx-target={@myself}
                      data-testid="next-step"
                      disabled={!(@selected_date && @selected_time)}
                      class="flex-1"
                    >
                      {gettext("next_step")} →
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
end
