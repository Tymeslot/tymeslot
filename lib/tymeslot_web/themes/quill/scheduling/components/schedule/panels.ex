defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.Schedule.Panels do
  @moduledoc """
  Extracted sub-components for the Quill schedule component:
  timezone selector, time slots panel, and formatting helpers.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Components.MeetingUtils
  alias TymeslotWeb.Live.Scheduling.Helpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Components.FlagHelpers

  # ========== TIMEZONE SELECTOR ==========

  attr :user_timezone, :string, required: true
  attr :timezone_search, :string, required: true
  attr :timezone_dropdown_open, :boolean, required: true
  attr :target, :any, required: true
  attr :locale, :string, required: true

  @spec timezone_selector(map()) :: Phoenix.LiveView.Rendered.t()
  def timezone_selector(assigns) do
    ~H"""
    <div class="relative" data-locale={@locale}>
      <%!-- Label: hidden on small screens --%>
      <label class="timezone-label font-medium">
        <div class="timezone-label-content">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          {gettext("Your timezone")}
        </div>
      </label>

      <div
        class="group relative cursor-pointer"
        phx-click="toggle_timezone_dropdown"
        phx-target={@target}
      >
        <div class="timezone-trigger rounded-xl transition-all duration-200 ease-out hover:shadow-lg">
          <div class="timezone-trigger-row">
            <div class="timezone-trigger-info flex-1 min-w-0">
              <.timezone_flag
                timezone={@user_timezone}
                class="timezone-flag shadow-sm"
                fallback_icon="🌐"
              />
              <div class="flex-1 min-w-0">
                <div class="timezone-name font-medium text-white truncate">
                  {Timezones.format(@user_timezone)}
                </div>
                <div class="timezone-time-display timezone-time-inline text-xs mt-1">
                  {get_current_time_display(@user_timezone)}
                </div>
              </div>
            </div>
            <div class="timezone-meta">
              <div class="timezone-offset-badge rounded-full font-medium">
                {get_timezone_offset(@user_timezone)}
              </div>
              <svg
                class={"timezone-chevron transition-transform duration-200 #{if @timezone_dropdown_open, do: "rotate-180", else: "rotate-0"}"}
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
        </div>
      </div>

    <%!-- Dropdown with search input at top - no layout shift --%>
      <%= if @timezone_dropdown_open do %>
        <div class="timezone-dropdown absolute top-full mt-1 z-[9999] rounded-xl shadow-2xl border overflow-hidden">
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
                  class="w-4 h-4 text-tymeslot-500"
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

          <div class="timezone-dropdown-list scroll-y">
            <div class="p-1">
              <%= for {label, value, offset} <- Timezones.search(@timezone_search) do %>
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

  # ========== TIME SLOTS PANEL ==========

  attr :selected_date, :string, default: nil
  attr :selected_time, :string, default: nil
  attr :available_slots, :list, default: []
  attr :loading_slots, :boolean, default: false
  attr :calendar_error, :string, default: nil
  attr :target, :any, required: true

  @spec time_slots_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def time_slots_panel(assigns) do
    ~H"""
    <div class="time-slots-panel flex flex-col" id="slots-container" phx-hook="AutoScrollToSlots">
      <% normalized_slots = MeetingUtils.normalize_slot_list(@available_slots) %>
      <h2 class="slots-heading font-bold text-glass-primary">
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
              <div class="space-y-3 pr-2" data-slots-loaded>
                <%= for {period, slots} <- LocalizationHelpers.group_slots_by_period(normalized_slots) do %>
                  <%= if length(slots) > 0 do %>
                    <div>
                      <div class="time-period-label text-xs font-semibold mb-2 px-1">
                        {period}
                      </div>
                      <div class="time-slots-grid">
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
          case MeetingUtils.normalize_slot_time(value) do
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
      {LocalizationHelpers.format_time_by_locale(@slot.start_time)}
    </button>
    """
  end

  # ========== FORMATTING HELPERS ==========

  @doc """
  Formats advance booking days for display.
  """
  @spec format_advance_booking_days(term()) :: String.t()
  def format_advance_booking_days(days) when is_integer(days) and days <= 0,
    do: gettext("same day only")

  def format_advance_booking_days(1), do: gettext("1 day in advance")

  def format_advance_booking_days(days) when is_integer(days) and days < 7,
    do: gettext("%{days} days in advance", days: days)

  def format_advance_booking_days(7), do: gettext("1 week in advance")

  def format_advance_booking_days(days) when is_integer(days) and days < 30,
    do: format_weeks_advance(days)

  def format_advance_booking_days(30), do: gettext("1 month in advance")

  def format_advance_booking_days(days) when is_integer(days) and days < 365,
    do: format_months_advance(days)

  def format_advance_booking_days(365), do: gettext("1 year in advance")
  def format_advance_booking_days(days) when is_integer(days), do: format_years_advance(days)
  def format_advance_booking_days(_arg), do: gettext("90 days in advance")

  # ========== PRIVATE HELPERS ==========

  defp get_current_time_display(timezone) do
    case DateTime.now(timezone) do
      {:ok, datetime} ->
        gettext("%{time} local time",
          time: String.slice(Time.to_string(DateTime.to_time(datetime)), 0, 5)
        )

      _other ->
        gettext("local time")
    end
  end

  defp get_timezone_offset(timezone) do
    Timezones.utc_offset(timezone)
  end

  defp get_timezone_local_time(timezone) do
    case DateTime.now(timezone) do
      {:ok, datetime} ->
        String.slice(Time.to_string(DateTime.to_time(datetime)), 0, 5)

      _other ->
        "--:--"
    end
  end

  defp format_weeks_advance(days), do: gettext("%{weeks} weeks in advance", weeks: div(days, 7))

  defp format_months_advance(days),
    do: gettext("%{months} months in advance", months: div(days, 30))

  defp format_years_advance(days), do: gettext("%{years} years in advance", years: div(days, 365))
end
