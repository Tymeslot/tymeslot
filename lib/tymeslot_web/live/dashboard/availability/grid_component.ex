defmodule TymeslotWeb.Dashboard.Availability.GridComponent do
  @moduledoc """
  LiveView component for grid-based availability display.
  Shows user's weekly availability schedule in a visual grid format.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Dashboard.Availability.Helpers

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    # Use profile data passed from parent component
    profile = assigns.profile
    weekly_schedule = assigns.weekly_schedule || []

    timezone_info = Helpers.get_timezone_info(profile)

    # Precompute day_of_week => availability map for faster lookups in render
    day_map = Map.new(weekly_schedule, &{&1.day_of_week, &1})

    socket =
      socket
      |> assign(assigns)
      |> assign(timezone_info)
      |> assign(:day_map, day_map)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Availability Grid -->
      <div class="card-glass relative overflow-x-auto">
        <!-- Timezone Display -->
        <div class="sm:absolute static sm:top-4 sm:right-4 mb-4 sm:mb-0">
          <Helpers.timezone_display timezone_display={@timezone_display} country_code={@country_code} />
        </div>

        <h4 class="text-lg font-semibold text-gray-800 mb-6">Weekly Availability Grid</h4>

        <div class="min-w-[600px]">
          <div class="grid grid-cols-8 gap-1 text-xs sm:text-sm">
            <!-- Header Row -->
            <div class="font-medium text-gray-600 text-center py-1 sm:py-3"></div>
            <%= for {day_name, _day_num} <- [{"Mon", 1}, {"Tue", 2}, {"Wed", 3}, {"Thu", 4}, {"Fri", 5}, {"Sat", 6}, {"Sun", 7}] do %>
              <div class="font-medium text-gray-800 text-center py-1 sm:py-3 bg-white/5 rounded border border-gray-200/20">
                {day_name}
              </div>
            <% end %>
            
    <!-- Time Slots Grid (30-minute intervals) -->
            <%= for hour <- 6..22 do %>
              <%= for minute <- [0, 30] do %>
                <div class="font-medium text-gray-600 text-right py-1 pr-1 sm:pr-2 text-[10px] sm:text-xs">
                  {format_time_slot(hour, minute)}
                </div>
                <%= for day_num <- 1..7 do %>
                  <% availability = Map.get(@day_map, day_num) %>
                  <% {slot_status, tooltip} = get_time_slot_status(availability, hour, minute) %>
                  <div
                    class={[
                      "h-3 sm:h-4 rounded border transition-all duration-200",
                      case slot_status do
                        :available -> "border-teal-500 hover:opacity-80"
                        :partial -> "border-yellow-500 hover:opacity-80"
                        :unavailable -> "bg-gray-100/20 border-gray-300/20 hover:bg-gray-100/30"
                      end
                    ]}
                    style={
                      case slot_status do
                        :available ->
                          "background-color: var(--color-primary-400); opacity: 0.8;"

                        :partial ->
                          "background: linear-gradient(45deg, var(--color-primary-400) 50%, #fbbf24 50%); opacity: 0.8;"

                        :unavailable ->
                          ""
                      end
                    }
                    title={tooltip}
                  >
                  </div>
                <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
        
    <!-- Legend -->
        <div class="mt-6 flex flex-wrap items-center justify-center gap-3 sm:gap-4 text-xs sm:text-sm">
          <div class="flex items-center space-x-2">
            <div
              class="w-3 h-3 sm:w-4 sm:h-4 border border-teal-500 rounded"
              style="background-color: var(--color-primary-400); opacity: 0.8;"
            >
            </div>
            <span class="text-gray-700">Available</span>
          </div>
          <div class="flex items-center space-x-2">
            <div
              class="w-3 h-3 sm:w-4 sm:h-4 border border-yellow-500 rounded"
              style="background: linear-gradient(45deg, var(--color-primary-400) 50%, #fbbf24 50%); opacity: 0.8;"
            >
            </div>
            <span class="text-gray-700">Partially Available</span>
          </div>
          <div class="flex items-center space-x-2">
            <div class="w-3 h-3 sm:w-4 sm:h-4 bg-gray-100/20 border border-gray-300/20 rounded"></div>
            <span class="text-gray-700">Unavailable</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper Functions

  defp format_time_slot(hour, 0) when hour < 12, do: "#{hour}:00"
  defp format_time_slot(hour, 30) when hour < 12, do: "#{hour}:30"
  defp format_time_slot(12, 0), do: "12:00"
  defp format_time_slot(12, 30), do: "12:30"
  defp format_time_slot(hour, 0) when hour > 12, do: "#{hour - 12}:00"
  defp format_time_slot(hour, 30) when hour > 12, do: "#{hour - 12}:30"

  defp get_time_slot_status(nil, _hour, _minute), do: {:unavailable, "Day not configured"}

  defp get_time_slot_status(%{is_available: false}, _hour, _minute),
    do: {:unavailable, "Day unavailable"}

  defp get_time_slot_status(%{is_available: true, start_time: nil}, _hour, _minute),
    do: {:unavailable, "No hours set"}

  defp get_time_slot_status(
         %{is_available: true, start_time: start_time, end_time: end_time, breaks: breaks},
         hour,
         minute
       ) do
    slot_start = Time.new!(hour, minute, 0)
    slot_end = Time.add(slot_start, 30, :minute)

    # Check if 30-minute slot overlaps with business hours
    slot_in_business_hours =
      Time.compare(slot_start, end_time) == :lt and Time.compare(slot_end, start_time) == :gt

    if slot_in_business_hours do
      check_breaks_for_slot(breaks, slot_start, slot_end)
    else
      {:unavailable, "Outside business hours"}
    end
  end

  defp check_breaks_for_slot(breaks, slot_start, slot_end) do
    # Check for break overlaps within this 30-minute slot
    overlapping_breaks = Enum.filter(breaks, &break_overlaps_slot?(&1, slot_start, slot_end))

    case overlapping_breaks do
      [] ->
        {:available, "Available for booking"}

      [break | _] ->
        get_break_status(break, slot_start, slot_end)
    end
  end

  defp break_overlaps_slot?(break, slot_start, slot_end) do
    Time.compare(break.start_time, slot_end) == :lt and
      Time.compare(break.end_time, slot_start) == :gt
  end

  defp get_break_status(break, slot_start, slot_end) do
    # Check if break covers the entire 30-minute slot
    break_covers_slot =
      Time.compare(break.start_time, slot_start) != :gt and
        Time.compare(break.end_time, slot_end) != :lt

    if break_covers_slot do
      {:unavailable, "Break: #{break.label || "Unavailable"}"}
    else
      {:partial, "Partially available (Break: #{break.label || "Break"} overlaps)"}
    end
  end
end
