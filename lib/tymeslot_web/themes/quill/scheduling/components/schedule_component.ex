defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent do
  @moduledoc """
  Quill theme component for the schedule/calendar step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.TimezoneUtils
  alias TymeslotWeb.Live.Scheduling.Helpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Components.FlagHelpers
  import TymeslotWeb.Components.MeetingComponents

  @impl true
  def update(assigns, socket) do
    # Filter out reserved assigns that can't be set directly
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl true
  def handle_event("select_date", %{"date" => date}, socket) do
    send(self(), {:step_event, :schedule, :select_date, date})
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_time", %{"time" => time}, socket) do
    send(self(), {:step_event, :schedule, :select_time, time})
    {:noreply, socket}
  end

  @impl true
  def handle_event("change_timezone", %{"timezone" => timezone}, socket) do
    send(self(), {:step_event, :schedule, :change_timezone, timezone})
    {:noreply, socket}
  end

  @impl true
  def handle_event("search_timezone", params, socket) do
    send(self(), {:step_event, :schedule, :search_timezone, params})
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_timezone_dropdown", _params, socket) do
    send(self(), {:step_event, :schedule, :toggle_timezone_dropdown, nil})
    {:noreply, socket}
  end

  @impl true
  def handle_event("close_timezone_dropdown", _params, socket) do
    send(self(), {:step_event, :schedule, :close_timezone_dropdown, nil})
    {:noreply, socket}
  end

  @impl true
  def handle_event("prev_month", _params, socket) do
    send(self(), {:step_event, :schedule, :prev_month, nil})
    {:noreply, socket}
  end

  @impl true
  def handle_event("next_month", _params, socket) do
    send(self(), {:step_event, :schedule, :next_month, nil})
    {:noreply, socket}
  end

  @impl true
  def handle_event("back_step", _params, socket) do
    send(self(), {:step_event, :schedule, :back_step, nil})
    {:noreply, socket}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    send(self(), {:step_event, :schedule, :next_step, nil})
    {:noreply, socket}
  end

  # Helper function to format advance booking days for display
  defp format_advance_booking_days(days) when is_integer(days) and days <= 0,
    do: gettext("same day only")

  defp format_advance_booking_days(1), do: gettext("1 day in advance")

  defp format_advance_booking_days(days) when is_integer(days) and days < 7,
    do: gettext("%{days} days in advance", days: days)

  defp format_advance_booking_days(7), do: gettext("1 week in advance")

  defp format_advance_booking_days(days) when is_integer(days) and days < 30,
    do: format_weeks_advance(days)

  defp format_advance_booking_days(30), do: gettext("1 month in advance")

  defp format_advance_booking_days(days) when is_integer(days) and days < 365,
    do: format_months_advance(days)

  defp format_advance_booking_days(365), do: gettext("1 year in advance")
  defp format_advance_booking_days(days) when is_integer(days), do: format_years_advance(days)
  defp format_advance_booking_days(_), do: gettext("90 days in advance")

  # Helper functions for formatting
  defp format_weeks_advance(days), do: gettext("%{weeks} weeks in advance", weeks: div(days, 7))

  defp format_months_advance(days),
    do: gettext("%{months} months in advance", months: div(days, 30))

  defp format_years_advance(days), do: gettext("%{years} years in advance", years: div(days, 365))

  @impl true
  def render(assigns) do
    ~H"""
    <div data-locale={@locale}>
      <.page_layout
        show_steps={true}
        current_step={2}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="container stack flex-1">
          <div class="flex-1 flex items-start justify-center px-4 py-2 md:py-4">
            <div class="w-full max-w-5xl min-h-0">
              <.glass_morphism_card class="calendar-card">
                <div class="p-2 md:p-3 lg:p-4 min-h-0">
                  <div class="flex flex-col md:flex-row md:items-start md:justify-between mb-3">
                    <div class="flex-1">
                      <.section_header
                        level={2}
                        class="mb-1"
                        title_class="section-header text-base md:text-lg lg:text-xl"
                      >
                        {gettext("Select a Date & Time")}
                      </.section_header>

                      <%= if @organizer_profile do %>
                        <p class="text-sm md:text-base mb-2 text-glass-primary">
                          {gettext("Bookings available up to %{advance}", advance: format_advance_booking_days(
                            @organizer_profile.advance_booking_days
                          ))}
                        </p>
                      <% end %>

                      <p
                        class="text-base md:text-lg font-medium text-glass-primary"
                      >
                        <%= if @meeting_type do %>
                          {gettext("Duration: %{duration}", duration: LocalizationHelpers.format_duration(@meeting_type.duration_minutes))}
                        <% else %>
                          {gettext("Duration: %{duration}", duration: TimezoneUtils.format_duration(@duration))}
                        <% end %>
                      </p>
                    </div>

                    <div class="mt-3 md:mt-0 md:ml-4">
                      <.timezone_selector
                        user_timezone={@user_timezone}
                        timezone_search={@timezone_search}
                        timezone_dropdown_open={@timezone_dropdown_open}
                        target={@myself}
                        locale={@locale}
                      />
                    </div>
                  </div>

                  <div class="flex flex-col lg:flex-row lg:gap-4 xl:gap-6 calendar-slots-container">
                    <div class="flex-1 calendar-section">
                      <div class="cluster cluster-between mb-1 md:mb-2">
                        <h2 class="text-sm md:text-base lg:text-lg font-bold cluster cluster-xs text-glass-primary">
                          {gettext("Select a Date")}
                          <%= if @availability_status == :loading do %>
                            <svg
                              class="animate-spin h-4 w-4 text-white opacity-60"
                              xmlns="http://www.w3.org/2000/svg"
                              fill="none"
                              viewBox="0 0 24 24"
                            >
                              <circle
                                class="opacity-25"
                                cx="12"
                                cy="12"
                                r="10"
                                stroke="currentColor"
                                stroke-width="4"
                              >
                              </circle>
                              <path
                                class="opacity-75"
                                fill="currentColor"
                                d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                              >
                              </path>
                            </svg>
                          <% end %>
                        </h2>
                        <div class="cluster cluster-3xs md:cluster-2xs">
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
                                Helpers.prev_month_disabled?(
                                  @current_year,
                                  @current_month,
                                  @user_timezone
                                )
                            }
                            class="calendar-nav-button p-1 md:p-2 rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse"
                          >
                            ←
                          </button>
                          <div class="text-xs md:text-sm lg:text-base font-semibold px-2 md:px-3 text-white">
                            {LocalizationHelpers.get_month_year_display(@current_year, @current_month)}
                          </div>
                          <button
                            phx-click="next_month"
                            phx-target={@myself}
                            phx-disable-with="..."
                            disabled={
                                Helpers.next_month_disabled?(
                                  @current_year,
                                  @current_month,
                                  @user_timezone
                                )
                            }
                            class="calendar-nav-button p-1 md:p-2 rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed phx-click-loading:animate-pulse"
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
                          <%= for day <- Helpers.get_calendar_days(@user_timezone, @current_year, @current_month, @organizer_profile, @month_availability_map) do %>
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

                    <.time_slots_panel
                      selected_date={@selected_date}
                      loading_slots={@loading_slots}
                      calendar_error={@calendar_error}
                      available_slots={@available_slots}
                      selected_time={@selected_time}
                      target={@myself}
                    />
                  </div>

                  <div class="mt-2 md:mt-3 flex gap-2 flex-shrink-0">
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

  # Helper functions for timezone display
  defp get_current_time_display(timezone) do
    case DateTime.now(timezone) do
      {:ok, datetime} ->
        gettext("%{time} local time",
          time: String.slice(Time.to_string(DateTime.to_time(datetime)), 0, 5)
        )

      _ ->
        gettext("local time")
    end
  end

  defp get_timezone_offset(timezone) do
    TimezoneUtils.get_current_utc_offset(timezone)
  end

  defp get_timezone_local_time(timezone) do
    case DateTime.now(timezone) do
      {:ok, datetime} ->
        String.slice(Time.to_string(DateTime.to_time(datetime)), 0, 5)

      _ ->
        "--:--"
    end
  end

  # Sub-components for better organization
  defp timezone_selector(assigns) do
    ~H"""
    <div class="relative w-full md:w-auto md:max-w-xs lg:max-w-sm" data-locale={@locale}>
      <label class="timezone-label text-sm font-medium block mb-2">
        <div class="cluster cluster-xs">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
            >
            </path>
          </svg>
          {gettext("Your timezone")}
        </div>
      </label>

    <!-- Current timezone display with modern card design -->
      <div
        class="group relative cursor-pointer"
        phx-click="toggle_timezone_dropdown"
        phx-target={@target}
      >
        <div class="timezone-trigger px-4 py-3 rounded-xl transition-all duration-200 ease-out hover:scale-[1.01] hover:shadow-lg">
          <div class="cluster cluster-between">
            <div class="cluster cluster-sm flex-1 min-w-0">
              <.timezone_flag
                timezone={@user_timezone}
                class="w-6 h-4 flex-shrink-0 rounded-sm shadow-sm"
                fallback_icon="🌐"
              />
              <div class="flex-1 min-w-0">
                <div class="text-sm font-medium text-white truncate">
                  {TimezoneUtils.format_timezone(@user_timezone)}
                </div>
                <div class="timezone-time-display text-xs mt-1">
                  {get_current_time_display(@user_timezone)}
                </div>
              </div>
            </div>
            <div class="cluster cluster-xs ml-3">
              <div class="timezone-offset-badge text-sm px-3 py-1.5 rounded-full font-medium">
                {get_timezone_offset(@user_timezone)}
              </div>
              <svg
                class={"timezone-chevron w-4 h-4 transition-transform duration-200 #{if @timezone_dropdown_open, do: "rotate-180", else: "rotate-0"}"}
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 9l-7 7-7-7"
                >
                </path>
              </svg>
            </div>
          </div>
        </div>
      </div>

    <!-- Dropdown with search input at top - no layout shift -->
      <%= if @timezone_dropdown_open do %>
        <div class="timezone-dropdown absolute top-full left-0 right-0 md:left-auto md:right-0 w-full md:min-w-[16rem] md:max-w-sm mt-1 max-h-64 md:max-h-72 z-[9999] rounded-xl shadow-2xl border overflow-hidden">
          <!-- Search input fixed at top of dropdown -->
          <div class="timezone-dropdown-header p-3">
            <div class="relative">
              <input
                id="timezone-search"
                type="text"
                phx-keyup="search_timezone"
                phx-blur="close_timezone_dropdown"
                phx-target={@target}
                name="search"
                value={@timezone_search}
                placeholder={gettext("Search cities, countries, or timezones...")}
                class="timezone-search-input w-full px-4 py-2 rounded-lg text-sm border-0 pr-10 focus:outline-none focus:ring-2 focus:ring-white/30"
                autocomplete="off"
                phx-hook="AutoFocus"
              />
              <div class="absolute right-3 top-1/2 transform -translate-y-1/2 pointer-events-none">
                <svg
                  class="w-4 h-4 text-gray-500"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                  >
                  </path>
                </svg>
              </div>
            </div>
          </div>

    <!-- Scrollable timezone options -->
          <div class="scroll-y max-h-48 md:max-h-56">
            <div class="p-1">
              <%= for {label, value, offset} <- TimezoneUtils.get_filtered_timezone_options(@timezone_search) do %>
                <div
                  phx-click="change_timezone"
                  phx-value-timezone={value}
                  phx-target={@target}
                  class="timezone-dropdown-item w-full text-left px-3 py-2.5 text-sm rounded-lg flex justify-between items-center cursor-pointer transition-all duration-150 group"
                >
                  <div class="flex-1 min-w-0">
                    <div class="font-medium truncate">{label}</div>
                    <div class="timezone-time-display text-xs mt-0.5">
                      {get_timezone_local_time(value)}
                    </div>
                  </div>
                  <div class="timezone-offset-badge-dropdown text-sm font-medium px-2.5 py-1 rounded-full transition-colors duration-150">
                    {offset}
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp time_slots_panel(assigns) do
    ~H"""
    <div class="time-slots-panel flex flex-col" id="slots-container" phx-hook="AutoScrollToSlots">
      <% normalized_slots = normalize_slot_list(@available_slots) %>
      <h2 class="text-sm md:text-base lg:text-lg font-bold mb-1 text-glass-primary">
        {gettext("Available Times")}
      </h2>
      <div class="slots-box flex-1">
        <%= if @selected_date do %>
          <%= if @loading_slots do %>
            <div class="h-full flex items-center justify-center">
              <.spinner />
              <span class="ml-3 text-white">{gettext("Loading available times...")}</span>
            </div>
          <% else %>
            <%= if @calendar_error do %>
              <.info_box variant={:warning}>
                {@calendar_error}
              </.info_box>
            <% end %>
            <%= if !@calendar_error && length(normalized_slots) > 0 do %>
              <div class="space-y-3 pr-2">
                <%= for {period, slots} <- LocalizationHelpers.group_slots_by_period(normalized_slots) do %>
                  <%= if length(slots) > 0 do %>
                    <div>
                      <div class="time-period-label text-xs font-semibold mb-2 px-1">
                        {period}
                      </div>
                      <div class="grid grid-cols-4 sm:grid-cols-5 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-1.5">
                        <%= for slot_value <- slots do %>
                          <.time_slot_button
                            phx-click="select_time"
                            phx-target={@target}
                            phx-value-time={slot_value}
                            slot={%{start_time: Helpers.parse_slot_time(slot_value)}}
                            selected={@selected_time == slot_value}
                            disabled={@loading_slots}
                          />
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            <% else %>
              <%= if !@calendar_error do %>
                <.empty_state
                  message={gettext("This date is fully booked")}
                  secondary_message={gettext("Please select another date")}
                >
                  <:icon>
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"
                    >
                    </path>
                  </:icon>
                </.empty_state>
              <% end %>
            <% end %>
          <% end %>
        <% else %>
          <div class="h-full flex items-center justify-center">
            <p class="text-quill-secondary text-sm">
              {gettext("Please select a date to see available times")}
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
