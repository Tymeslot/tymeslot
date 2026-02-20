defmodule TymeslotWeb.Components.MeetingComponents do
  @moduledoc """
  Components specific to meetings, scheduling, and calendars.
  These components understand the meeting domain.
  """
  use TymeslotWeb, :html
  alias Calendar
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.DateTimeUtils

  # ========== MEETING DISPLAY ==========

  @doc """
  Renders a meeting details card with consistent styling.
  """
  attr :title, :string, default: ""
  slot :inner_block, required: true

  @spec meeting_details_card(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_details_card(assigns) do
    ~H"""
    <div class="meeting-details-card">
      <%= if @title && @title != "" do %>
        <h3 class="text-lg font-semibold mb-4 text-purple-900">{@title}</h3>
      <% end %>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a meeting summary with all key details.
  """
  attr :meeting, :map, required: true
  attr :timezone, :string, required: true
  attr :show_actions, :boolean, default: false

  @spec meeting_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_summary(assigns) do
    assigns =
      assigns
      |> assign_new(:title, fn -> "Meeting Details" end)
      |> assign_new(:date_label, fn -> "Date" end)
      |> assign_new(:time_label, fn -> "Time" end)
      |> assign_new(:duration_label, fn -> "Duration" end)
      |> assign_new(:with_label, fn -> "With" end)
      |> assign_new(:reschedule_label, fn -> "Reschedule" end)
      |> assign_new(:cancel_label, fn -> "Cancel" end)
      |> assign_new(:formatted_date, fn -> format_date(assigns.meeting.start_time) end)
      |> assign_new(:formatted_time, fn ->
        format_time(assigns.meeting.start_time, assigns.timezone)
      end)
      |> assign_new(:formatted_duration, fn -> "#{assigns.meeting.duration} minutes" end)

    ~H"""
    <.meeting_details_card title={@title}>
      <dl class="space-y-3">
        <.detail_row label={@date_label} value={@formatted_date} />
        <.detail_row label={@time_label} value={@formatted_time} />
        <.detail_row label={@duration_label} value={@formatted_duration} />
        <.detail_row label={@with_label} value={@meeting.organizer_name} />
      </dl>

      <%= if @show_actions do %>
        <div class="mt-4 flex gap-2">
          <.link navigate={@meeting.reschedule_url} class="action-button action-button--secondary">
            {@reschedule_label}
          </.link>
          <.link navigate={@meeting.cancel_url} class="action-button action-button--danger">
            {@cancel_label}
          </.link>
        </div>
      <% end %>
    </.meeting_details_card>
    """
  end

  @doc """
  Renders booking details in a grid layout.
  """
  attr :date, :string, required: true
  attr :time, :string, required: true
  attr :duration, :string, required: true
  attr :timezone, :string, required: true
  attr :variant, :atom, default: :compact, values: [:compact, :expanded]

  @spec booking_details(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_details(assigns) do
    grid_class =
      case assigns.variant do
        :expanded -> "grid grid-cols-2 md:grid-cols-4 gap-2 text-xs"
        _other -> "grid grid-cols-2 gap-2 text-xs"
      end

    assigns =
      assigns
      |> assign(:grid_class, grid_class)
      |> assign_new(:date_label, fn -> "Date" end)
      |> assign_new(:time_label, fn -> "Time" end)
      |> assign_new(:duration_label, fn -> "Duration" end)
      |> assign_new(:timezone_label, fn -> "Timezone" end)
      |> assign_new(:formatted_date, fn -> format_date(assigns.date) end)
      |> assign_new(:formatted_duration, fn -> format_duration(assigns.duration) end)
      |> assign_new(:formatted_timezone, fn -> format_timezone(assigns.timezone) end)

    ~H"""
    <div class={@grid_class}>
      <div>
        <p class="booking-detail-label">{@date_label}</p>
        <p class="booking-detail-value">{@formatted_date}</p>
      </div>
      <div>
        <p class="booking-detail-label">{@time_label}</p>
        <p class="booking-detail-value">{@time}</p>
      </div>
      <div>
        <p class="booking-detail-label">{@duration_label}</p>
        <p class="booking-detail-value">{@formatted_duration}</p>
      </div>
      <div>
        <p class="booking-detail-label">{@timezone_label}</p>
        <p class="booking-detail-value">{@formatted_timezone}</p>
      </div>
    </div>
    """
  end

  # ========== CALENDAR & TIME ==========

  @doc """
  Renders a calendar day cell.
  """
  attr :day, :map, required: true
  attr :selected, :boolean, default: false
  attr :available, :boolean, default: true
  attr :current_month, :boolean, default: true
  attr :loading, :boolean, default: false
  attr :rest, :global

  @spec calendar_day(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_day(assigns) do
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

  @spec normalize_slot_time(term()) :: {:ok, String.t()} | :error
  def normalize_slot_time(slot) do
    normalize_slot_value(slot)
  end

  @spec normalize_slot_value(term()) :: {:ok, String.t()} | :error
  defp normalize_slot_value(slot) when is_binary(slot) do
    {:ok, slot}
  end

  defp normalize_slot_value(%Time{} = slot) do
    {:ok, DateTimeUtils.format_time_for_display(slot)}
  end

  defp normalize_slot_value(%NaiveDateTime{} = slot) do
    {:ok, slot |> NaiveDateTime.to_time() |> DateTimeUtils.format_time_for_display()}
  end

  defp normalize_slot_value(%DateTime{} = slot) do
    {:ok, slot |> DateTime.to_time() |> DateTimeUtils.format_time_for_display()}
  end

  defp normalize_slot_value(%{} = slot) do
    value =
      Map.get(slot, :time) ||
        Map.get(slot, "time") ||
        Map.get(slot, :start_time) ||
        Map.get(slot, "start_time")

    normalize_slot_value(value)
  end

  defp normalize_slot_value(_other), do: :error

  @spec normalize_slot_list(term()) :: [String.t()]
  def normalize_slot_list(slots) when is_list(slots) do
    Enum.flat_map(slots, fn slot ->
      case normalize_slot_time(slot) do
        {:ok, value} -> [value]
        :error -> []
      end
    end)
  end

  def normalize_slot_list(_other), do: []

  @doc """
  Renders a time slot button.
  """
  attr :slot, :map, required: true
  attr :selected, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :rest, :global

  @spec time_slot_button(map()) :: Phoenix.LiveView.Rendered.t()
  def time_slot_button(assigns) do
    # Ensure @rest does not contain map values that Protocol.HTML.Safe cannot handle.
    # Specifically, phx-value-time might be a map if passed directly from slots.
    assigns =
      case Map.get(assigns.rest, :"phx-value-time") do
        nil ->
          assigns

        value ->
          case normalize_slot_time(value) do
            {:ok, time_val} -> put_in(assigns, [:rest, :"phx-value-time"], time_val)
            :error -> update_in(assigns, [:rest], &Map.delete(&1, :"phx-value-time"))
          end
      end

    ~H"""
    <button
      class={[
        "time-slot-button",
        @selected && "time-slot-button--selected"
      ]}
      data-testid="time-slot"
      disabled={@disabled}
      {@rest}
    >
      {format_time_by_locale(@slot.start_time)}
    </button>
    """
  end

  @doc """
  Renders calendar navigation controls.
  """
  attr :current_display, :string, required: true
  attr :prev_disabled, :boolean, default: false
  attr :next_disabled, :boolean, default: false
  attr :on_prev, :string, default: "prev_month"
  attr :on_next, :string, default: "next_month"

  @spec calendar_navigation(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_navigation(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-1 md:mb-2">
      <h2 class="text-sm md:text-base lg:text-lg font-bold" style="color: white;">Select a Date</h2>
      <div class="flex items-center gap-1 md:gap-2">
        <button
          phx-click={@on_prev}
          disabled={@prev_disabled}
          class={[
            "p-1.5 md:p-2 rounded-lg transition-all",
            if @prev_disabled do
              "cursor-not-allowed opacity-30"
            else
              "hover:scale-105 cursor-pointer"
            end
          ]}
          style="background: rgba(255,255,255,0.2); color: white;"
        >
          <svg class="w-3 h-3 md:w-4 md:h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7">
            </path>
          </svg>
        </button>
        <div class="text-xs md:text-sm lg:text-base font-semibold px-2 md:px-3" style="color: white;">
          {@current_display}
        </div>
        <button
          phx-click={@on_next}
          disabled={@next_disabled}
          class={[
            "p-1.5 md:p-2 rounded-lg transition-all",
            if @next_disabled do
              "cursor-not-allowed opacity-30"
            else
              "hover:scale-105 cursor-pointer"
            end
          ]}
          style="background: rgba(255,255,255,0.2); color: white;"
        >
          <svg class="w-3 h-3 md:w-4 md:h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7">
            </path>
          </svg>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a duration selection card.
  """
  attr :duration, :string, required: true
  attr :title, :string, required: true
  attr :badge, :string, default: nil
  attr :description, :string, required: true
  attr :icon, :string, required: true
  attr :selected, :boolean, default: false
  attr :target, :any, default: nil

  @spec duration_card(map()) :: Phoenix.LiveView.Rendered.t()
  def duration_card(assigns) do
    ~H"""
    <button
      phx-click="select_duration"
      phx-value-duration={@duration}
      phx-target={@target}
      data-testid="duration-option"
      data-duration={@duration}
      class={"w-full p-2.5 sm:p-3 md:p-5 rounded-xl transition-all duration-300 cursor-pointer transform #{if @selected, do: "scale-105", else: "hover:scale-105"}"}
      style={duration_card_style(@selected, @duration)}
    >
      <div class="flex items-center justify-between">
        <div class="text-left flex-1">
          <div class="flex items-start justify-between gap-2 mb-1">
            <h3 class="text-base sm:text-lg md:text-xl font-bold flex-1" style="color: white;">
              {@title}
            </h3>
            <span
              class="inline-block px-2 py-0.5 text-xs font-semibold rounded-full whitespace-nowrap mt-1"
              style="background: rgba(255,255,255,0.2); color: rgba(255,255,255,0.95); backdrop-filter: blur(10px);"
            >
              {@badge || @duration}
            </span>
          </div>
          <p
            class="text-xs sm:text-sm md:text-base"
            style={"color: rgba(255,255,255,#{if @selected, do: "0.9", else: "0.8"});"}
          >
            {@description}
          </p>
        </div>
        <%= if @icon != "none" do %>
          <%= if String.starts_with?(@icon, "hero-") do %>
            <.icon name={@icon} class="w-6 h-6 sm:w-8 sm:h-8 md:w-10 md:h-10 text-white" />
          <% else %>
            <div class="text-xl sm:text-2xl md:text-3xl">{@icon}</div>
          <% end %>
        <% end %>
      </div>
    </button>
    """
  end

  @doc """
  Renders the calendar grid with selectable days.
  """
  attr :current_year, :integer, required: true
  attr :current_month, :integer, required: true
  attr :selected_date, :string, default: nil
  attr :user_timezone, :string, required: true
  attr :organizer_user_id, :integer, default: nil

  @spec calendar_grid(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_grid(assigns) do
    ~H"""
    <div>
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
        <%= for day <- get_calendar_days(@user_timezone, @current_year, @current_month, @organizer_user_id) do %>
          <.calendar_day
            phx-click="select_date"
            phx-value-date={day[:date]}
            day={Map.put(day, :is_today, day[:today])}
            selected={@selected_date == day[:date]}
            available={day[:available] && !day[:past]}
            current_month={day[:current_month]}
          />
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders the availability section with time slots.
  """
  attr :selected_date, :string, default: nil
  attr :selected_time, :string, default: nil
  attr :available_slots, :list, default: []
  attr :loading_slots, :boolean, default: false
  attr :calendar_error, :string, default: nil

  @spec availability_section(map()) :: Phoenix.LiveView.Rendered.t()
  def availability_section(assigns) do
    ~H"""
    <div>
      <h2 class="text-sm md:text-base lg:text-lg font-bold mb-1" style="color: white;">
        Available Times
      </h2>
      <div class="slots-box flex-1">
        <% normalized_slots = normalize_slot_list(@available_slots) %>
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
            <%= if !@calendar_error && length(normalized_slots) > 0 do %>
              <div class="space-y-3 pr-2">
                <%= for {period, slots} <- group_slots_by_period(normalized_slots) do %>
                  <%= if length(slots) > 0 do %>
                    <div>
                      <div
                        class="text-xs font-semibold mb-2 px-1"
                        style="color: rgba(255,255,255,0.8);"
                      >
                        {period}
                      </div>
                      <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-2 lg:grid-cols-3 gap-2">
                        <%= for slot_value <- slots do %>
                          <.time_slot_button
                            phx-click="select_time"
                            phx-value-time={slot_value}
                            slot={%{start_time: parse_slot_time(slot_value)}}
                            selected={@selected_time == slot_value}
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

  # ========== NAVIGATION ==========

  @doc """
  Renders step navigation buttons (back/next pattern).
  """
  attr :back_action, :string, required: true
  attr :next_action, :string, default: "next_step"
  attr :next_enabled, :boolean, default: true
  attr :next_label, :string, default: "Next Step →"
  attr :loading, :boolean, default: false
  attr :loading_text, :string, default: "Processing..."

  @spec step_navigation_buttons(map()) :: Phoenix.LiveView.Rendered.t()
  def step_navigation_buttons(assigns) do
    ~H"""
    <div class="mt-3 flex gap-2">
      <.action_button type="button" phx-click={@back_action} variant={:secondary} class="flex-1">
        ← Back
      </.action_button>

      <.loading_button
        type="submit"
        phx-click={@next_action}
        disabled={!@next_enabled}
        loading={@loading}
        loading_text={@loading_text}
        class="flex-1"
      >
        {@next_label}
      </.loading_button>
    </div>
    """
  end

  # ========== PRIVATE HELPERS ==========

  defp get_calendar_days(user_timezone, year, month, organizer_user_id) do
    # Get the user's profile settings
    settings = Profiles.get_profile_settings(organizer_user_id)

    config = %{
      max_advance_booking_days: settings.advance_booking_days,
      min_advance_hours: settings.min_advance_hours
    }

    Calculate.get_calendar_days(user_timezone, year, month, config)
  end

  defp group_slots_by_period(slots) do
    grouped = DateTimeUtils.group_slots_by_period(slots)

    # Return in consistent order: Night, Morning, Afternoon, Evening
    [
      {"Night", Map.get(grouped, "Night", [])},
      {"Morning", Map.get(grouped, "Morning", [])},
      {"Afternoon", Map.get(grouped, "Afternoon", [])},
      {"Evening", Map.get(grouped, "Evening", [])}
    ]
  end

  defp parse_slot_time(slot_string) do
    case DateTimeUtils.parse_slot_time(slot_string) do
      {:ok, time} ->
        # Return a DateTime for today with the parsed time
        {:ok, dt} = DateTime.new(Date.utc_today(), time)
        dt

      {:error, _reason} ->
        # Fallback to current time if parsing fails
        DateTime.utc_now()
    end
  end

  defp format_date(date_string) when is_binary(date_string) do
    DateTimeUtils.format_date_string(date_string)
  end

  defp format_date(%Date{} = date) do
    Calendar.strftime(date, "%B %d, %Y")
  end

  defp format_date(%DateTime{} = datetime) do
    datetime |> DateTime.to_date() |> format_date()
  end

  defp format_time(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} ->
        Calendar.strftime(shifted, "%H:%M") <> " " <> shifted.zone_abbr

      _other ->
        Calendar.strftime(datetime, "%H:%M") <> " UTC"
    end
  end

  defp format_time_by_locale(dt) do
    Calendar.strftime(dt, "%H:%M")
  end

  defp format_duration(duration) when is_binary(duration) do
    DateTimeUtils.format_duration(duration)
  end

  defp format_duration(duration) when is_integer(duration) do
    "#{duration} minutes"
  end

  defp format_timezone(timezone) do
    Timezones.format(timezone)
  end

  defp duration_card_style(selected, duration) do
    base_style =
      if selected do
        case duration do
          d when d in ["15min", "15-minutes"] ->
            "background: linear-gradient(135deg, #4a1d6d 0%, #2d1b69 100%); box-shadow: 0 10px 30px rgba(74,29,109,0.4);"

          d when d in ["30min", "30-minutes"] ->
            "background: linear-gradient(135deg, #6a1b9a 0%, #4a148c 100%); box-shadow: 0 10px 30px rgba(106,27,154,0.4);"

          _other ->
            "background: linear-gradient(135deg, #4a1d6d 0%, #2d1b69 100%); box-shadow: 0 10px 30px rgba(74,29,109,0.4);"
        end
      else
        "background: rgba(255,255,255,0.1); hover:background: rgba(255,255,255,0.15);"
      end

    border =
      if selected do
        "border: 2px solid rgba(255,255,255,0.3);"
      else
        "border: 2px solid transparent;"
      end

    base_style <> " " <> border
  end
end
