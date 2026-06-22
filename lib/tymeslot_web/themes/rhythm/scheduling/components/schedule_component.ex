defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.ScheduleComponent do
  @moduledoc """
  Rhythm theme component for the schedule (date/time selection) step.
  Extracted from the monolithic RhythmSlidesComponent to improve separation of concerns.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Components.MeetingUtils
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Live.Scheduling.CalendarNavigation
  alias TymeslotWeb.Themes.Rhythm.Shared.OrganizerHeader
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    filtered_assigns = Map.drop(assigns, [:flash, :socket])

    {:ok, assign(socket, filtered_assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_date", %{"date" => date}, socket) do
    new_date = if socket.assigns[:selected_date] == date, do: nil, else: date

    socket =
      socket
      |> assign(:selected_date, new_date)
      |> assign(:selected_time, nil)

    send(self(), {:step_event, :schedule, :select_date, new_date})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_time", %{"time" => time}, socket) do
    new_time = if socket.assigns[:selected_time] == time, do: nil, else: time
    send(self(), {:step_event, :schedule, :select_time, new_time})
    {:noreply, assign(socket, :selected_time, new_time)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change_timezone", %{"timezone" => timezone}, socket) do
    send(self(), {:step_event, :schedule, :change_timezone, timezone})

    {:noreply,
     socket
     |> assign(:timezone_dropdown_open, false)
     |> assign(:timezone_search, "")}
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
  def handle_event("search_timezone", params, socket) do
    send(self(), {:step_event, :schedule, :search_timezone, params})
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
  def handle_event("prev_slide", _params, socket) do
    send(self(), {:step_event, :schedule, :back_step, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("next_slide", _params, socket) do
    send(self(), {:step_event, :schedule, :next_step, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="scheduling-box" data-locale={@locale}>
      <div class="slide-container">
        <div class="slide active">
          <div class="slide-content schedule-slide">
            <div class="schedule-header">
              <OrganizerHeader.organizer_header_small
                organizer_profile={@organizer_profile}
                meeting_type={@meeting_type}
                selected_duration={@selected_duration}
              />
              <div class="timezone-selector-container">
                <label class="timezone-label">{dgettext("booking", "Your timezone")}:</label>
                <div class="timezone-dropdown-wrapper">
                  <.dropdown
                    id="rhythm-timezone-dropdown"
                    open={@timezone_dropdown_open}
                    on_toggle="toggle_timezone_dropdown"
                    on_close="close_timezone_dropdown"
                    target={@myself}
                    role="dialog"
                    panel_label={dgettext("booking", "Select timezone")}
                    trigger_class="timezone-trigger"
                    class="timezone-dropdown"
                    unstyled={true}
                    aria-label={dgettext("booking", "Select timezone")}
                  >
                  <:trigger>
                    <div class="timezone-display">
                      <%= if country_code = Timezones.country_code(@user_timezone || "America/New_York") do %>
                        <%= if Timezones.flag_exists?(country_code) do %>
                          <Flagpack.flag name={country_code} class="timezone-flag" />
                        <% else %>
                          <span class="timezone-flag timezone-flag--fallback">🌐</span>
                        <% end %>
                      <% end %>
                      <span class="timezone-text">
                        {Timezones.format(@user_timezone || "America/New_York")}
                      </span>
                    </div>
                    <div class="timezone-arrow">▼</div>
                  </:trigger>
                  <:panel>
                    <div class="timezone-search-wrapper">
                      <input
                        id="timezone-search-input"
                        type="text"
                        placeholder={dgettext("booking", "Search cities, countries, or timezones...")}
                        class="timezone-search"
                        phx-keyup="search_timezone"
                        phx-target={@myself}
                        name="search"
                        value={@timezone_search}
                        phx-hook="AutoFocus"
                      />
                    </div>
                    <div class="timezone-options scroll-y">
                      <%= for {label, value, offset} <- Timezones.search(@timezone_search) do %>
                        <button
                          class="timezone-option"
                          phx-click="change_timezone"
                          phx-value-timezone={value}
                          phx-target={@myself}
                          type="button"
                        >
                          <div class="timezone-option-content">
                            <%= if country_code = Timezones.country_code(value) do %>
                              <%= if Timezones.flag_exists?(country_code) do %>
                                <Flagpack.flag name={country_code} class="timezone-option-flag" />
                              <% else %>
                                <span class="timezone-option-flag timezone-flag--fallback">🌐</span>
                              <% end %>
                            <% end %>
                            <div class="timezone-option-text">
                              <div class="timezone-option-label">{label}</div>
                              <div class="timezone-option-offset">{offset}</div>
                            </div>
                          </div>
                        </button>
                      <% end %>
                    </div>
                  </:panel>
                </.dropdown>
                </div>
              </div>
            </div>

            <div class="schedule-grid">
              <div class="calendar-section calendar-section-wrapper">
                <div class="calendar-header">
                  <button
                    class="calendar-nav-button phx-click-loading:animate-pulse"
                    phx-click="prev_week"
                    phx-target={@myself}
                    phx-disable-with="..."
                    disabled={CalendarNavigation.prev_week_disabled?(@current_week_start, @user_timezone)}
                  >
                    ←
                  </button>
                  <h3 class="calendar-month-year">{LocalizationHelpers.get_week_display(@current_week_start)}</h3>
                  <div class="cluster cluster-xs">
                    <%= if @availability_status in [:error, :timeout] do %>
                      <div class="calendar-error-inline">
                        <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                        </svg>
                        {dgettext("booking", "Service slow")}
                      </div>
                    <% end %>
                    <button
                      class="calendar-nav-button phx-click-loading:animate-pulse"
                      phx-click="next_week"
                      phx-target={@myself}
                      phx-disable-with="..."
                      disabled={CalendarNavigation.next_week_disabled?(@current_week_start, @user_timezone, @organizer_profile.advance_booking_days)}
                    >
                      →
                    </button>
                  </div>
                </div>

                <div class="calendar-grid">
                  <%= for day <- CalendarHelpers.get_week_days(@current_week_start, @organizer_profile, @month_availability_map, @user_timezone) do %>
                    <button
                      class={[
                        "calendar-day",
                        @selected_date == day.date && "selected",
                        day.loading && "calendar-day--loading"
                      ]}
                      data-testid="calendar-day"
                      data-date={day.date}
                      phx-click="select_date"
                      phx-value-date={day.date}
                      phx-target={@myself}
                      disabled={not day.available || day.loading}
                    >
                      <div class="day-name">{day.day_name}</div>
                      <div class="day-number">{day.day_number}</div>
                    </button>
                  <% end %>
                </div>
              </div>

              <div class="time-slots-section">
                <h3 class="time-slots-section-heading">{dgettext("booking", "Available Times")}</h3>
                <% normalized_slots = MeetingUtils.normalize_slot_list(@available_slots) %>
                <div class="time-slots-grid scroll-y">
                  <%= if @selected_date do %>
                    <%= if @loading_slots do %>
                      <div class="loading-slots">
                        <span>{dgettext("booking", "Loading available times...")}</span>
                      </div>
                    <% else %>
                      <%= if @calendar_error do %>
                        <div class="calendar-error">
                          {@calendar_error}
                        </div>
                      <% end %>
                      <%= if !@calendar_error && length(normalized_slots) > 0 do %>
                        <%= for {period, slots} <- LocalizationHelpers.group_slots_by_period(normalized_slots) do %>
                          <%= if length(slots) > 0 do %>
                            <div class="time-period-section">
                              <h4 class="time-period-header">
                                {period}
                              </h4>
                              <div class="time-period-slots">
                                <%= for slot_value <- slots do %>
                                  <button
                                    class={"time-slot #{if @selected_time == slot_value, do: "selected", else: ""}"}
                                    data-testid="time-slot"
                                    data-time={slot_value}
                                    phx-click="select_time"
                                    phx-value-time={slot_value}
                                    phx-target={@myself}
                                    disabled={@loading_slots}
                                  >
                                    {LocalizationHelpers.format_time_by_locale(CalendarHelpers.parse_slot_time(slot_value))}
                                  </button>
                                <% end %>
                              </div>
                            </div>
                          <% end %>
                        <% end %>
                      <% else %>
                        <%= if !@calendar_error do %>
                          <div class="no-slots">
                            <p>{dgettext("booking", "This date is fully booked")}</p>
                            <p>{dgettext("booking", "Please select another date")}</p>
                          </div>
                        <% end %>
                      <% end %>
                    <% end %>
                  <% else %>
                    <div class="no-slots">
                      <p>{dgettext("booking", "Please select a date to see available times")}</p>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <div class="slide-actions horizontal">
              <button
                :if={@entered_via_overview}
                class="prev-button"
                phx-click="prev_slide"
                phx-target={@myself}
                data-testid="back-step"
              >
                ← {dgettext("booking", "back")}
              </button>
              <button
                class={
                  if @selected_date && @selected_time, do: "next-button", else: "next-button disabled"
                }
                phx-click="next_slide"
                phx-target={@myself}
                data-testid="next-step"
                disabled={is_nil(@selected_date) or is_nil(@selected_time)}
              >
                {dgettext("booking", "next")} →
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
