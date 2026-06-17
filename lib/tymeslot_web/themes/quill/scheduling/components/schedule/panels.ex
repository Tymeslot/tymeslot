defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.Schedule.Panels do
  @moduledoc """
  Extracted sub-components for the Quill schedule component:
  timezone selector, time slots panel, and formatting helpers.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Components.MeetingUtils
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.TimezoneHelpers

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
      <label class="timezone-label">
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
      </label>

      <div class="timezone-dropdown-wrapper">
        <.dropdown
          id="quill-timezone-dropdown"
          open={@timezone_dropdown_open}
          on_toggle="toggle_timezone_dropdown"
          on_close="close_timezone_dropdown"
          target={@target}
          role="dialog"
          panel_label={dgettext("booking", "Select timezone")}
          trigger_class="timezone-trigger"
          class="timezone-dropdown"
          unstyled={true}
          aria-label={dgettext("booking", "Select timezone")}
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
        <:panel>
          <div class="timezone-search-wrapper">
            <input
              id="timezone-search"
              type="text"
              class="timezone-search"
              phx-keyup="search_timezone"
              phx-target={@target}
              name="search"
              value={@timezone_search}
              placeholder={dgettext("booking", "Search cities, countries, or timezones...")}
              autocomplete="off"
              phx-hook="AutoFocus"
            />
          </div>
          <div class="timezone-options scroll-y">
            <%= for {label, value, offset} <- Timezones.search(@timezone_search) do %>
              <button
                class="timezone-option"
                phx-click="change_timezone"
                phx-value-timezone={value}
                phx-target={@target}
                type="button"
              >
                <div class="timezone-option-content">
                  <.timezone_flag timezone={value} class="timezone-option-flag" fallback_icon="🌐" />
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
        {dgettext("booking", "Available Times")}
      </h2>
      <div class="slots-box flex-1">
        <%= if @selected_date do %>
          <%= if @loading_slots do %>
            <div class="h-full flex items-center justify-center">
              <.spinner />
              <span class="ml-3 text-white">{dgettext("booking", "Loading available times...")}</span>
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
                            slot={%{start_time: CalendarHelpers.parse_slot_time(slot_value)}}
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
                  message={dgettext("booking", "This date is fully booked")}
                  secondary_message={dgettext("booking", "Please select another date")}
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
              {dgettext("booking", "Please select a date to see available times")}
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
    do: dgettext("booking", "same day only")

  def format_advance_booking_days(1), do: dgettext("booking", "1 day in advance")

  def format_advance_booking_days(days) when is_integer(days) and days < 7,
    do: dgettext("booking", "%{days} days in advance", days: days)

  def format_advance_booking_days(7), do: dgettext("booking", "1 week in advance")

  def format_advance_booking_days(days) when is_integer(days) and days < 30,
    do: format_weeks_advance(days)

  def format_advance_booking_days(30), do: dgettext("booking", "1 month in advance")

  def format_advance_booking_days(days) when is_integer(days) and days < 365,
    do: format_months_advance(days)

  def format_advance_booking_days(365), do: dgettext("booking", "1 year in advance")
  def format_advance_booking_days(days) when is_integer(days), do: format_years_advance(days)
  def format_advance_booking_days(_arg), do: dgettext("booking", "90 days in advance")

  # ========== PRIVATE HELPERS ==========

  defp format_weeks_advance(days),
    do: dgettext("booking", "%{weeks} weeks in advance", weeks: div(days, 7))

  defp format_months_advance(days),
    do: dgettext("booking", "%{months} months in advance", months: div(days, 30))

  defp format_years_advance(days),
    do: dgettext("booking", "%{years} years in advance", years: div(days, 365))
end
