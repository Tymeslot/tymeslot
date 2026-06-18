defmodule TymeslotWeb.Dashboard.MeetingSettings.Components.SchedulingSettings do
  @moduledoc "Scheduling constraint components for meeting type forms."
  use Phoenix.Component

  @doc """
  Component for configuring buffer time between appointments.
  """
  attr :profile, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec buffer_minutes_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def buffer_minutes_setting(assigns) do
    assigns =
      assign(
        assigns,
        :buffer_value,
        if(assigns.profile, do: assigns.profile.buffer_minutes, else: 0)
      )

    ~H"""
    <div>
      <label class="label">
        Buffer Between Appointments
      </label>

    <%!-- Tag-based Selection --%>
      <form id="buffer-minutes-form" phx-change="update_buffer_minutes" phx-debounce="300" phx-target={@myself}>
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
              if(@buffer_value == minutes and not @custom_mode, do: "btn-tag-selector-primary--active")
            ]}
          >
            <%= if minutes == 0 do %>
              No buffer
            <% else %>
              {minutes} min
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
              min
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
            Custom
          </button>
        <% end %>
      </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        Time to block after each appointment for preparation, travel, or breaks.
      </p>
    </div>
    """
  end

  @doc """
  Component for configuring how far in advance appointments can be booked.
  """
  attr :profile, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec advance_booking_days_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def advance_booking_days_setting(assigns) do
    assigns =
      assign(
        assigns,
        :booking_days,
        if(assigns.profile, do: assigns.profile.advance_booking_days, else: 90)
      )

    ~H"""
    <div>
      <label class="label">
        How Far in Advance Can People Book
      </label>

    <%!-- Tag-based Selection --%>
      <form id="advance-booking-days-form" phx-change="update_advance_booking_days" phx-debounce="300" phx-target={@myself}>
      <div class="flex flex-wrap items-center gap-3">
        <%!-- Quick preset tags --%>
        <%= for {days, label} <- [
          {7, "1 week"},
          {14, "2 weeks"},
          {30, "1 month"},
          {60, "2 months"},
          {90, "3 months"},
          {180, "6 months"}
        ] do %>
          <button
            type="button"
            phx-click="update_advance_booking_days"
            phx-value-advance_booking_days={days}
            phx-value-_preset="true"
            phx-target={@myself}
            class={[
              "btn-tag-selector btn-tag-selector-secondary",
              if(@booking_days == days and not @custom_mode, do: "btn-tag-selector-secondary--active")
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
              days
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
            Custom
          </button>
        <% end %>
      </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        Maximum number of days into the future that appointments can be booked.
      </p>
    </div>
    """
  end

  @doc """
  Component for configuring minimum booking notice required.
  """
  attr :profile, :map, required: true
  attr :myself, :any, required: true
  attr :custom_mode, :boolean, required: true

  @spec min_advance_hours_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def min_advance_hours_setting(assigns) do
    assigns =
      assign(
        assigns,
        :notice_hours,
        if(assigns.profile, do: assigns.profile.min_advance_hours, else: 24)
      )

    ~H"""
    <div>
      <label class="label">
        Minimum Booking Notice
      </label>

    <%!-- Tag-based Selection --%>
      <form id="min-advance-hours-form" phx-change="update_min_advance_hours" phx-debounce="300" phx-target={@myself}>
      <div class="flex flex-wrap items-center gap-3">
        <%!-- Quick preset tags --%>
        <%= for {hours, label} <- [
          {0, "instant"},
          {1, "1 hour"},
          {4, "4 hours"},
          {24, "1 day"},
          {48, "2 days"},
          {168, "1 week"}
        ] do %>
          <button
            type="button"
            phx-click="update_min_advance_hours"
            phx-value-min_advance_hours={hours}
            phx-value-_preset="true"
            phx-target={@myself}
            class={[
              "btn-tag-selector btn-tag-selector-tertiary",
              if(@notice_hours == hours and not @custom_mode, do: "btn-tag-selector-tertiary--active")
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
              hours
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
            Custom
          </button>
        <% end %>
      </div>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        Minimum hours of notice required before an appointment can be booked.
      </p>
    </div>
    """
  end
end
