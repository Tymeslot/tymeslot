defmodule TymeslotWeb.Dashboard.Availability.PolicyCard do
  @moduledoc """
  Scheduling policy card for the availability page.

  Buffer, advance booking window and minimum notice belong to a single named
  schedule, so they are edited here beside the weekly pattern they constrain
  rather than on the account-wide meeting settings page.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Renders the three scheduling policy settings for one schedule.
  """
  attr :schedule, :map, required: true
  attr :myself, :any, required: true
  attr :custom_input_mode, :map, required: true

  @spec policy_card(map()) :: Phoenix.LiveView.Rendered.t()
  def policy_card(assigns) do
    ~H"""
    <div class="card-glass shadow-2xl shadow-tymeslot-200/50">
      <.section_header
        level={2}
        icon="hero-clock"
        title={dgettext("dashboard_availability", "Scheduling Preferences")}
        class="mb-4"
      />

      <p class="mb-10 text-token-sm text-tymeslot-500 font-bold">
        {dgettext(
          "dashboard_availability",
          "These rules apply to every meeting type booked against this schedule."
        )}
      </p>

      <div class="space-y-8">
        <.buffer_minutes_setting
          schedule={@schedule}
          myself={@myself}
          custom_mode={Map.get(@custom_input_mode, :buffer_minutes, false)}
        />
        <.advance_booking_days_setting
          schedule={@schedule}
          myself={@myself}
          custom_mode={Map.get(@custom_input_mode, :advance_booking_days, false)}
        />
        <.min_advance_hours_setting
          schedule={@schedule}
          myself={@myself}
          custom_mode={Map.get(@custom_input_mode, :min_advance_hours, false)}
        />
      </div>
    </div>
    """
  end

  @doc """
  Component for configuring buffer time between appointments.
  """
  attr :schedule, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec buffer_minutes_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def buffer_minutes_setting(assigns) do
    assigns =
      assign(
        assigns,
        :buffer_value,
        if(assigns.schedule, do: assigns.schedule.buffer_minutes, else: 0)
      )

    ~H"""
    <div>
      <label class="label">
        {dgettext("dashboard_availability", "Buffer Between Appointments")}
      </label>

      <%!-- Tag-based Selection --%>
      <form
        id="buffer-minutes-form"
        phx-change="update_buffer_minutes"
        phx-debounce="300"
        phx-target={@myself}
      >
        <div class="flex flex-wrap items-center gap-3">
          <%!-- Quick preset tags --%>
          <%= for minutes <- [0, 5, 10, 15, 30, 60] do %>
            <button
              type="button"
              phx-click="update_buffer_minutes"
              phx-value-buffer_minutes={minutes}
              phx-value-_preset="true"
              phx-target={@myself}
              class={[
                "btn-tag-selector btn-tag-selector-primary",
                if(@buffer_value == minutes and not @custom_mode,
                  do: "btn-tag-selector-primary--active"
                )
              ]}
            >
              <%= if minutes == 0 do %>
                {dgettext("dashboard_availability", "No buffer")}
              <% else %>
                {dgettext("dashboard_availability", "%{minutes} min", minutes: minutes)}
              <% end %>
            </button>
          <% end %>

          <%!-- Custom input tag --%>
          <%= if @custom_mode or @buffer_value not in [0, 5, 10, 15, 30, 60] do %>
            <div class="btn-tag-selector btn-tag-selector-primary--active p-0! overflow-hidden">
              <input
                type="number"
                min="0"
                max="120"
                step="5"
                value={@buffer_value}
                name="buffer_minutes"
                class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-hidden rounded-l-xl"
                placeholder="0"
              />
              <span class="pr-3 py-2 text-token-sm font-black text-turquoise-700">
                {dgettext("dashboard_availability", "min")}
              </span>
            </div>
          <% else %>
            <button
              type="button"
              phx-click="focus_custom_input"
              phx-value-setting="buffer_minutes"
              phx-target={@myself}
              class="btn-tag-selector btn-tag-selector-primary"
            >
              {dgettext("dashboard_availability", "Custom")}
            </button>
          <% end %>
        </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        {dgettext(
          "dashboard_availability",
          "Time to block after each appointment for preparation, travel, or breaks."
        )}
      </p>
    </div>
    """
  end

  @doc """
  Component for configuring how far in advance appointments can be booked.
  """
  attr :schedule, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec advance_booking_days_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def advance_booking_days_setting(assigns) do
    assigns =
      assign(
        assigns,
        :booking_days,
        if(assigns.schedule, do: assigns.schedule.advance_booking_days, else: 90)
      )

    ~H"""
    <div>
      <label class="label">
        {dgettext("dashboard_availability", "How Far in Advance Can People Book")}
      </label>

      <%!-- Tag-based Selection --%>
      <form
        id="advance-booking-days-form"
        phx-change="update_advance_booking_days"
        phx-debounce="300"
        phx-target={@myself}
      >
        <div class="flex flex-wrap items-center gap-3">
          <%!-- Quick preset tags --%>
          <%= for {days, label} <- [
          {7, dgettext("dashboard_availability", "1 week")},
          {14, dgettext("dashboard_availability", "2 weeks")},
          {30, dgettext("dashboard_availability", "1 month")},
          {60, dgettext("dashboard_availability", "2 months")},
          {90, dgettext("dashboard_availability", "3 months")},
          {180, dgettext("dashboard_availability", "6 months")}
        ] do %>
            <button
              type="button"
              phx-click="update_advance_booking_days"
              phx-value-advance_booking_days={days}
              phx-value-_preset="true"
              phx-target={@myself}
              class={[
                "btn-tag-selector btn-tag-selector-secondary",
                if(@booking_days == days and not @custom_mode,
                  do: "btn-tag-selector-secondary--active"
                )
              ]}
            >
              {label}
            </button>
          <% end %>

          <%!-- Custom input tag --%>
          <%= if @custom_mode or @booking_days not in [7, 14, 30, 60, 90, 180] do %>
            <div class="btn-tag-selector btn-tag-selector-secondary--active p-0! overflow-hidden">
              <input
                type="number"
                min="1"
                max="365"
                step="1"
                value={@booking_days}
                name="advance_booking_days"
                class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-hidden rounded-l-xl"
                placeholder="90"
              />
              <span class="pr-3 py-2 text-token-sm font-black text-cyan-700">
                {dgettext("dashboard_availability", "days")}
              </span>
            </div>
          <% else %>
            <button
              type="button"
              phx-click="focus_custom_input"
              phx-value-setting="advance_booking_days"
              phx-target={@myself}
              class="btn-tag-selector btn-tag-selector-secondary"
            >
              {dgettext("dashboard_availability", "Custom")}
            </button>
          <% end %>
        </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        {dgettext(
          "dashboard_availability",
          "Maximum number of days into the future that appointments can be booked."
        )}
      </p>
    </div>
    """
  end

  @doc """
  Component for configuring minimum booking notice required.
  """
  attr :schedule, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec min_advance_hours_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def min_advance_hours_setting(assigns) do
    assigns =
      assign(
        assigns,
        :notice_hours,
        if(assigns.schedule, do: assigns.schedule.min_advance_hours, else: 24)
      )

    ~H"""
    <div>
      <label class="label">
        {dgettext("dashboard_availability", "Minimum Booking Notice")}
      </label>

      <%!-- Tag-based Selection --%>
      <form
        id="min-advance-hours-form"
        phx-change="update_min_advance_hours"
        phx-debounce="300"
        phx-target={@myself}
      >
        <div class="flex flex-wrap items-center gap-3">
          <%!-- Quick preset tags --%>
          <%= for {hours, label} <- [
          {0, dgettext("dashboard_availability", "instant")},
          {1, dgettext("dashboard_availability", "1 hour")},
          {4, dgettext("dashboard_availability", "4 hours")},
          {24, dgettext("dashboard_availability", "1 day")},
          {48, dgettext("dashboard_availability", "2 days")},
          {168, dgettext("dashboard_availability", "1 week")}
        ] do %>
            <button
              type="button"
              phx-click="update_min_advance_hours"
              phx-value-min_advance_hours={hours}
              phx-value-_preset="true"
              phx-target={@myself}
              class={[
                "btn-tag-selector btn-tag-selector-tertiary",
                if(@notice_hours == hours and not @custom_mode,
                  do: "btn-tag-selector-tertiary--active"
                )
              ]}
            >
              {label}
            </button>
          <% end %>

          <%!-- Custom input tag --%>
          <%= if @custom_mode or @notice_hours not in [0, 1, 4, 24, 48, 168] do %>
            <div class="btn-tag-selector btn-tag-selector-tertiary--active p-0! overflow-hidden">
              <input
                type="number"
                min="0"
                max="168"
                step="1"
                value={@notice_hours}
                name="min_advance_hours"
                class="w-20 px-3 py-2 text-token-sm font-black bg-transparent border-0 focus:ring-0 focus:outline-hidden rounded-l-xl"
                placeholder="24"
              />
              <span class="pr-3 py-2 text-token-sm font-black text-blue-700">
                {dgettext("dashboard_availability", "hours")}
              </span>
            </div>
          <% else %>
            <button
              type="button"
              phx-click="focus_custom_input"
              phx-value-setting="min_advance_hours"
              phx-target={@myself}
              class="btn-tag-selector btn-tag-selector-tertiary"
            >
              {dgettext("dashboard_availability", "Custom")}
            </button>
          <% end %>
        </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        {dgettext(
          "dashboard_availability",
          "Minimum hours of notice required before an appointment can be booked."
        )}
      </p>
    </div>
    """
  end
end
