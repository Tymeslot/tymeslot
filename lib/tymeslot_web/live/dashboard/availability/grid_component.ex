defmodule TymeslotWeb.Dashboard.Availability.GridComponent do
  @moduledoc """
  LiveView component for grid-based availability display.
  Shows user's weekly availability schedule in a visual grid format.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Dashboard.Availability.Helpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
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

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-8 animate-in fade-in duration-500">
      <!-- Availability Grid -->
      <div class="card-glass relative overflow-x-auto shadow-2xl shadow-tymeslot-200/50">
        <div class="flex flex-col md:flex-row md:items-center justify-between mb-10 gap-6">
          <.section_header
            level={2}
            icon={:grid}
            title="Weekly Visual Grid"
          />
          
          <div class="flex-shrink-0">
            <Helpers.timezone_display timezone_display={@timezone_display} country_code={@country_code} />
          </div>
        </div>

        <div class="min-w-[800px] bg-tymeslot-50/50 rounded-token-3xl p-6 border-2 border-tymeslot-50">
          <div class="grid grid-cols-8 gap-2 text-xs sm:text-sm">
            <!-- Header Row -->
            <div class="font-black text-tymeslot-400 uppercase tracking-widest text-center py-4"></div>
            <%= for {day_name, _day_number} <- [{"Mon", 1}, {"Tue", 2}, {"Wed", 3}, {"Thu", 4}, {"Fri", 5}, {"Sat", 6}, {"Sun", 7}] do %>
              <div class="font-black text-tymeslot-700 text-center py-4 bg-white rounded-token-xl border-2 border-white shadow-sm">
                {day_name}
              </div>
            <% end %>
            
    <!-- Time Slots Grid (30-minute intervals) -->
            <%= for hour <- 6..22 do %>
              <%= for minute <- [0, 30] do %>
                <div class="font-black text-tymeslot-400 text-right py-1 pr-4 text-[10px] sm:text-xs uppercase tracking-tighter">
                  {format_time_slot(hour, minute)}
                </div>
                <%= for day_num <- 1..7 do %>
                  <% availability = Map.get(@day_map, day_num) %>
                  <% {slot_status, tooltip} = get_time_slot_status(availability, hour, minute) %>
                  <div
                    class={[
                      "h-5 sm:h-6 rounded-token-lg border-2 transition-all duration-300 transform hover:scale-110 hover:z-10",
                      case slot_status do
                        :available -> "border-emerald-200 shadow-sm shadow-emerald-500/10 cursor-pointer"
                        :partial -> "border-amber-200 shadow-sm shadow-amber-500/10 cursor-pointer"
                        :unavailable -> "bg-tymeslot-100 border-tymeslot-100 opacity-40 hover:opacity-100"
                      end
                    ]}
                    style={
                      case slot_status do
                        :available ->
                          "background-color: #10b981; opacity: 0.8;"

                        :partial ->
                          "background: linear-gradient(45deg, #10b981 50%, #f59e0b 50%); opacity: 0.8;"

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
        <div class="mt-10 flex flex-wrap items-center justify-center gap-8 bg-tymeslot-50/50 p-6 rounded-token-2xl border-2 border-tymeslot-50">
          <div class="flex items-center gap-3">
            <div
              class="w-5 h-5 border-2 border-emerald-200 rounded-token-lg shadow-sm"
              style="background-color: #10b981; opacity: 0.8;"
            >
            </div>
            <span class="text-tymeslot-700 font-bold text-sm">Full Availability</span>
          </div>
          <div class="flex items-center gap-3">
            <div
              class="w-5 h-5 border-2 border-amber-200 rounded-token-lg shadow-sm"
              style="background: linear-gradient(45deg, #10b981 50%, #f59e0b 50%); opacity: 0.8;"
            >
            </div>
            <span class="text-tymeslot-700 font-bold text-sm">Partial (Breaks)</span>
          </div>
          <div class="flex items-center gap-3">
            <div class="w-5 h-5 bg-tymeslot-200 border-2 border-tymeslot-200 rounded-token-lg opacity-40"></div>
            <span class="text-tymeslot-700 font-bold text-sm">Unavailable</span>
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

      [break | _rest] ->
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
