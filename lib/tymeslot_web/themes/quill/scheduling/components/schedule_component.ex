defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent do
  @moduledoc """
  Quill theme component for the schedule/calendar step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Utils.TimezoneUtils
  alias TymeslotWeb.Live.Scheduling.Helpers

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
  defp format_advance_booking_days(days) when is_integer(days) and days <= 0, do: "same day only"
  defp format_advance_booking_days(1), do: "1 day in advance"

  defp format_advance_booking_days(days) when is_integer(days) and days < 7,
    do: "#{days} days in advance"

  defp format_advance_booking_days(7), do: "1 week in advance"

  defp format_advance_booking_days(days) when is_integer(days) and days < 30,
    do: format_weeks_advance(days)

  defp format_advance_booking_days(30), do: "1 month in advance"

  defp format_advance_booking_days(days) when is_integer(days) and days < 365,
    do: format_months_advance(days)

  defp format_advance_booking_days(365), do: "1 year in advance"
  defp format_advance_booking_days(days) when is_integer(days), do: format_years_advance(days)
  defp format_advance_booking_days(_), do: "90 days in advance"

  # Helper functions for formatting
  defp format_weeks_advance(days), do: "#{div(days, 7)} weeks in advance"
  defp format_months_advance(days), do: "#{div(days, 30)} months in advance"
  defp format_years_advance(days), do: "#{div(days, 365)} years in advance"

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_layout
        show_steps={true}
        current_step={2}
        duration={@duration}
        username_context={@username_context}
      >
        <div class="container flex-1 flex flex-col">
          <div class="flex-1 flex items-start justify-center px-4 py-2 md:py-4">
            <div class="w-full max-w-5xl min-h-0">
              <.glass_morphism_card class="calendar-card">
                <div class="p-2 md:p-3 lg:p-4 min-h-0">
                  <div class="flex flex-col md:flex-row md:items-start md:justify-between mb-3">
                    <div class="flex-1">
                      <.section_header level={2} class="text-base md:text-lg lg:text-xl mb-1">
                        Select a Date & Time
                      </.section_header>

                      <%= if @organizer_profile do %>
                        <p class="text-sm md:text-base mb-2" style="color: rgba(255,255,255,0.8);">
                          Bookings available up to {format_advance_booking_days(
                            @organizer_profile.advance_booking_days
                          )}
                        </p>
                      <% end %>

                      <p
                        class="text-base md:text-lg font-medium"
                        style="color: rgba(255,255,255,0.9);"
                      >
                        Duration: {TimezoneUtils.format_duration(@duration)}
                      </p>
                    </div>

                    <div class="mt-3 md:mt-0 md:ml-4">
                      <.timezone_selector
                        user_timezone={@user_timezone}
                        timezone_search={@timezone_search}
                        timezone_dropdown_open={@timezone_dropdown_open}
                        target={@myself}
                      />
                    </div>
                  </div>

                  <div class="flex flex-col lg:flex-row lg:gap-4 xl:gap-6 calendar-slots-container">
                    <div class="flex-1 calendar-section">
                      <div class="flex items-center justify-between mb-1 md:mb-2">
                        <h2 class="text-sm md:text-base lg:text-lg font-bold" style="color: white;">
                          Select a Date
                        </h2>
                        <div class="flex items-center gap-1 md:gap-2">
                          <button
                            phx-click="prev_month"
                            phx-target={@myself}
                            disabled={
                              Helpers.prev_month_disabled?(
                                @current_year,
                                @current_month,
                                @user_timezone
                              )
                            }
                            class="p-1 md:p-2 rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
                            style="background: rgba(255,255,255,0.1); color: white; border: 1px solid rgba(255,255,255,0.3); hover:background: rgba(255,255,255,0.2);"
                          >
                            ←
                          </button>
                          <div
                            class="text-xs md:text-sm lg:text-base font-semibold px-2 md:px-3"
                            style="color: white;"
                          >
                            {Helpers.get_month_year_display(@current_year, @current_month)}
                          </div>
                          <button
                            phx-click="next_month"
                            phx-target={@myself}
                            disabled={
                              Helpers.next_month_disabled?(
                                @current_year,
                                @current_month,
                                @user_timezone
                              )
                            }
                            class="p-1 md:p-2 rounded-lg transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
                            style="background: rgba(255,255,255,0.1); color: white; border: 1px solid rgba(255,255,255,0.3); hover:background: rgba(255,255,255,0.2);"
                          >
                            →
                          </button>
                        </div>
                      </div>
                      <div class="calendar-grid-container flex-1">
                        <div class="grid grid-cols-7 gap-0.5 text-center mb-1">
                          <div
                            :for={day <- ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]}
                            class="text-xs font-medium"
                            style="color: rgba(255,255,255,0.8);"
                          >
                            {String.slice(day, 0, 2)}
                          </div>
                        </div>
                        <div class="grid grid-cols-7 gap-0.5">
                          <%= for day <- Helpers.get_calendar_days(@user_timezone, @current_year, @current_month, @organizer_profile) do %>
                            <.calendar_day
                              phx-click="select_date"
                              phx-target={@myself}
                              phx-value-date={day[:date]}
                              day={Map.put(day, :is_today, day[:today])}
                              selected={@selected_date == day[:date]}
                              available={day[:available] && !day[:past]}
                              current_month={day[:current_month]}
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
                      variant={:secondary}
                      class="flex-1"
                    >
                      ← Back
                    </.action_button>

                    <.action_button
                      phx-click="next_step"
                      phx-target={@myself}
                      disabled={!(@selected_date && @selected_time)}
                      class="flex-1"
                    >
                      Next Step →
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
        Kernel.<>(String.slice(Time.to_string(DateTime.to_time(datetime)), 0, 5), " local time")

      _ ->
        "Local time"
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
    <div class="relative w-full md:w-auto md:max-w-xs lg:max-w-sm">
      <label class="text-sm font-medium block mb-2" style="color: rgba(255,255,255,0.9);">
        <div class="flex items-center gap-2">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
            >
            </path>
          </svg>
          Your timezone
        </div>
      </label>
      
    <!-- Current timezone display with modern card design -->
      <div
        class="group relative cursor-pointer"
        phx-click="toggle_timezone_dropdown"
        phx-target={@target}
      >
        <div
          class="px-4 py-3 rounded-xl transition-all duration-200 ease-out hover:scale-[1.01] hover:shadow-lg"
          style="background: linear-gradient(135deg, rgba(255,255,255,0.15) 0%, rgba(255,255,255,0.05) 100%);
                 border: 1px solid rgba(255,255,255,0.2);
                 backdrop-filter: blur(20px);"
        >
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3 flex-1 min-w-0">
              <.timezone_flag
                timezone={@user_timezone}
                class="w-6 h-4 flex-shrink-0 rounded-sm shadow-sm"
                fallback_icon="🌐"
              />
              <div class="flex-1 min-w-0">
                <div class="text-sm font-medium text-white truncate">
                  {TimezoneUtils.format_timezone(@user_timezone)}
                </div>
                <div class="text-xs mt-1" style="color: rgba(255,255,255,0.7);">
                  {get_current_time_display(@user_timezone)}
                </div>
              </div>
            </div>
            <div class="flex items-center gap-2 ml-3">
              <div
                class="text-sm px-3 py-1.5 rounded-full font-medium"
                style="background: rgba(255,255,255,0.15); color: rgba(255,255,255,0.9);"
              >
                {get_timezone_offset(@user_timezone)}
              </div>
              <svg
                class={"w-4 h-4 transition-transform duration-200 #{if @timezone_dropdown_open, do: "rotate-180", else: "rotate-0"}"}
                fill="none"
                stroke="currentColor"
                style="color: rgba(255,255,255,0.7);"
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
        <div
          class="absolute top-full left-0 right-0 md:left-auto md:right-0 w-full md:min-w-[16rem] md:max-w-sm mt-1 max-h-64 md:max-h-72 z-[9999] rounded-xl shadow-2xl border overflow-hidden"
          style="background: linear-gradient(135deg, rgba(45,25,70,0.9) 0%, rgba(30,15,50,0.85) 100%);
                 backdrop-filter: blur(20px);
                 border: 1px solid rgba(255,255,255,0.3);"
        >
          <!-- Search input fixed at top of dropdown -->
          <div class="p-3" style="border-bottom: 1px solid rgba(255,255,255,0.2);">
            <div class="relative">
              <input
                id="timezone-search"
                type="text"
                phx-keyup="search_timezone"
                phx-blur="close_timezone_dropdown"
                phx-target={@target}
                name="search"
                value={@timezone_search}
                placeholder="Search cities, countries, or timezones..."
                class="w-full px-4 py-2 rounded-lg text-sm border-0 pr-10 focus:outline-none focus:ring-2 focus:ring-white/30"
                style="background: rgba(255,255,255,0.9); color: #2d3436;"
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
          <div class="max-h-48 md:max-h-56 overflow-y-auto">
            <div class="p-1">
              <%= for {label, value, offset} <- TimezoneUtils.get_filtered_timezone_options(@timezone_search) do %>
                <div
                  phx-click="change_timezone"
                  phx-value-timezone={value}
                  phx-target={@target}
                  class="w-full text-left px-3 py-2.5 text-sm rounded-lg flex justify-between items-center cursor-pointer transition-all duration-150 group"
                  style="color: rgba(255,255,255,0.95);
                         hover:background: rgba(255,255,255,0.2);"
                  onmouseover="this.style.background='rgba(255,255,255,0.15)'"
                  onmouseout="this.style.background='transparent'"
                >
                  <div class="flex-1 min-w-0">
                    <div class="font-medium truncate">{label}</div>
                    <div class="text-xs mt-0.5" style="color: rgba(255,255,255,0.7);">
                      {get_timezone_local_time(value)}
                    </div>
                  </div>
                  <div
                    class="text-sm font-medium px-2.5 py-1 rounded-full transition-colors duration-150"
                    style="background: rgba(255,255,255,0.1); color: rgba(255,255,255,0.9);"
                  >
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
      <h2 class="text-sm md:text-base lg:text-lg font-bold mb-1" style="color: white;">
        Available Times
      </h2>
      <div class="slots-box flex-1">
        <%= if @selected_date do %>
          <%= if @loading_slots do %>
            <div class="h-full flex items-center justify-center">
              <.spinner />
              <span class="ml-3 text-white">Loading available times...</span>
            </div>
          <% else %>
            <%= if @calendar_error do %>
              <.info_box variant={:warning}>
                {@calendar_error}
              </.info_box>
            <% end %>
            <%= if !@calendar_error && length(@available_slots) > 0 do %>
              <div class="space-y-3 pr-2">
                <%= for {period, slots} <- Helpers.group_slots_by_period(@available_slots) do %>
                  <%= if length(slots) > 0 do %>
                    <div>
                      <div
                        class="text-xs font-semibold mb-2 px-1"
                        style="color: rgba(255,255,255,0.8);"
                      >
                        {period}
                      </div>
                      <div class="grid grid-cols-4 sm:grid-cols-5 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-1.5">
                        <%= for slot <- slots do %>
                          <.time_slot_button
                            phx-click="select_time"
                            phx-target={@target}
                            phx-value-time={slot}
                            slot={%{start_time: Helpers.parse_slot_time(slot)}}
                            selected={@selected_time == slot}
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
                  message="This date is fully booked"
                  secondary_message="Please select another date"
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
            <p class="text-sm" style="color: rgba(255,255,255,0.7);">
              Please select a date to see available times
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
