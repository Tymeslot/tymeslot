defmodule TymeslotWeb.Dashboard.MeetingSettings.Components do
  @moduledoc """
  Reusable components for meeting scheduling settings.
  Includes buffer time, advance booking, and minimum notice settings.
  """
  use Phoenix.Component

  @doc """
  Component for configuring buffer time between appointments.
  """
  attr :profile, :map, required: true
  attr :myself, :any, required: true

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
      
    <!-- Tag-based Selection -->
      <div class="flex flex-wrap items-center gap-2">
        <!-- Quick preset tags -->
        <%= for minutes <- [0, 5, 10, 15, 30, 60] do %>
          <button
            type="button"
            phx-click="update_buffer_minutes"
            phx-value-buffer_minutes={minutes}
            phx-target={@myself}
            class={[
              "inline-flex items-center px-3 py-2 rounded-full text-sm font-medium transition-all duration-200",
              if(@buffer_value == minutes,
                do: "bg-teal-100 text-teal-800 border border-teal-300",
                else: "bg-gray-100 text-gray-700 border border-gray-300 hover:bg-gray-200"
              )
            ]}
          >
            <%= if minutes == 0 do %>
              No buffer
            <% else %>
              {minutes} min
            <% end %>
          </button>
        <% end %>
        
    <!-- Custom input tag -->
        <%= if @buffer_value not in [0, 5, 10, 15, 30, 60] do %>
          <div class={[
            "inline-flex items-center rounded-full border transition-all duration-200",
            "bg-teal-100 text-teal-800 border-teal-300"
          ]}>
            <input
              type="number"
              min="0"
              max="120"
              step="5"
              value={@buffer_value}
              phx-blur="update_buffer_minutes"
              phx-target={@myself}
              name="buffer_minutes"
              class="w-16 px-2.5 py-2 text-sm bg-transparent border-0 focus:ring-0 focus:outline-none rounded-l-full"
              placeholder="0"
            />
            <span class="px-2.5 py-2 text-sm text-teal-800">
              min
            </span>
          </div>
        <% else %>
          <button
            type="button"
            phx-click="focus_custom_input"
            phx-value-setting="buffer_minutes"
            phx-target={@myself}
            class="inline-flex items-center px-3 py-2 rounded-full text-sm font-medium transition-all duration-200 bg-gray-100 text-gray-700 border border-gray-300 hover:bg-gray-200"
          >
            Custom
          </button>
        <% end %>
      </div>

      <p class="mt-2 text-sm text-gray-600">
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
      
    <!-- Tag-based Selection -->
      <div class="flex flex-wrap items-center gap-2">
        <!-- Quick preset tags -->
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
            phx-target={@myself}
            class={[
              "inline-flex items-center px-3 py-2 rounded-full text-sm font-medium transition-all duration-200",
              if(@booking_days == days,
                do: "bg-blue-100 text-blue-800 border border-blue-300",
                else: "bg-gray-100 text-gray-700 border border-gray-300 hover:bg-gray-200"
              )
            ]}
          >
            {label}
          </button>
        <% end %>
        
    <!-- Custom input tag -->
        <%= if @booking_days not in [7, 14, 30, 60, 90, 180] do %>
          <div class={[
            "inline-flex items-center rounded-full border transition-all duration-200",
            "bg-blue-100 text-blue-800 border-blue-300"
          ]}>
            <input
              type="number"
              min="1"
              max="365"
              step="1"
              value={@booking_days}
              phx-blur="update_advance_booking_days"
              phx-target={@myself}
              name="advance_booking_days"
              class="w-16 px-2.5 py-2 text-sm bg-transparent border-0 focus:ring-0 focus:outline-none rounded-l-full"
              placeholder="90"
            />
            <span class="px-2.5 py-2 text-sm text-blue-800">
              days
            </span>
          </div>
        <% else %>
          <button
            type="button"
            phx-click="focus_custom_input"
            phx-value-setting="advance_booking_days"
            phx-target={@myself}
            class="inline-flex items-center px-3 py-2 rounded-full text-sm font-medium transition-all duration-200 bg-gray-100 text-gray-700 border border-gray-300 hover:bg-gray-200"
          >
            Custom
          </button>
        <% end %>
      </div>

      <p class="mt-2 text-sm text-gray-600">
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
      
    <!-- Tag-based Selection -->
      <div class="flex flex-wrap items-center gap-2">
        <!-- Quick preset tags -->
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
            phx-target={@myself}
            class={[
              "inline-flex items-center px-3 py-2 rounded-full text-sm font-medium transition-all duration-200",
              if(@notice_hours == hours,
                do: "bg-purple-100 text-purple-800 border border-purple-300",
                else: "bg-gray-100 text-gray-700 border border-gray-300 hover:bg-gray-200"
              )
            ]}
          >
            {label}
          </button>
        <% end %>
        
    <!-- Custom input tag -->
        <%= if @notice_hours not in [0, 1, 4, 24, 48, 168] do %>
          <div class={[
            "inline-flex items-center rounded-full border transition-all duration-200",
            "bg-purple-100 text-purple-800 border-purple-300"
          ]}>
            <input
              type="number"
              min="0"
              max="168"
              step="1"
              value={@notice_hours}
              phx-blur="update_min_advance_hours"
              phx-target={@myself}
              name="min_advance_hours"
              class="w-16 px-2.5 py-2 text-sm bg-transparent border-0 focus:ring-0 focus:outline-none rounded-l-full"
              placeholder="24"
            />
            <span class="px-2.5 py-2 text-sm text-purple-800">
              hours
            </span>
          </div>
        <% else %>
          <button
            type="button"
            phx-click="focus_custom_input"
            phx-value-setting="min_advance_hours"
            phx-target={@myself}
            class="inline-flex items-center px-3 py-2 rounded-full text-sm font-medium transition-all duration-200 bg-gray-100 text-gray-700 border border-gray-300 hover:bg-gray-200"
          >
            Custom
          </button>
        <% end %>
      </div>

      <p class="mt-2 text-sm text-gray-600">
        Minimum hours of notice required before an appointment can be booked.
      </p>
    </div>
    """
  end
end
