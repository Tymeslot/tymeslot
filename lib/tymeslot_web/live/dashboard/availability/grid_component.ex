defmodule TymeslotWeb.Dashboard.Availability.GridComponent do
  @moduledoc """
  LiveView component for grid-based availability display.
  Shows user's weekly availability schedule in a visual grid format.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Dashboard.Availability.Helpers

  # Grid spans 6:00 AM to 10:30 PM (990 minutes total)
  @grid_start_minutes 6 * 60
  @grid_total_minutes 990
  @slot_duration_minutes 30

  @days [
    {"Monday", 1},
    {"Tuesday", 2},
    {"Wednesday", 3},
    {"Thursday", 4},
    {"Friday", 5},
    {"Saturday", 6},
    {"Sunday", 7}
  ]

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    profile = assigns.profile
    weekly_schedule = assigns.weekly_schedule || []

    timezone_info = Helpers.get_timezone_info(profile)

    day_map = Map.new(weekly_schedule, &{&1.day_of_week, &1})

    socket =
      socket
      |> assign(assigns)
      |> assign(timezone_info)
      |> assign(:day_map, day_map)
      |> assign(:days, @days)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-8 animate-in fade-in duration-500">
      <div class="card-glass relative shadow-2xl shadow-tymeslot-200/50">
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

        <%!-- Mobile: day-by-day timeline bars --%>
        <div class="sm:hidden space-y-2">
          <%= for {day_name, day_num} <- @days do %>
            <% avail = Map.get(@day_map, day_num) %>
            <% row = mobile_row_data(avail) %>
            <div class="flex items-center gap-3 py-1">
              <span class={["w-20 shrink-0 text-xs font-bold", if(row.active, do: "text-tymeslot-700", else: "text-tymeslot-400")]}>
                {day_name}
              </span>
              <div class="relative flex-1 h-6 bg-tymeslot-100 rounded-full overflow-hidden">
                <%= if row.active do %>
                  <div
                    class="absolute top-0 bottom-0 rounded-full opacity-80"
                    style={"left: #{row.left}%; width: #{row.width}%; background-color: #10b981;"}
                  >
                  </div>
                  <%= for seg <- row.breaks do %>
                    <div
                      class="absolute top-0 bottom-0 opacity-90"
                      style={"left: #{seg.left}%; width: #{seg.width}%; background-color: #f59e0b;"}
                      title={seg.label}
                    >
                    </div>
                  <% end %>
                <% end %>
              </div>
              <span class={["w-28 shrink-0 text-right text-[11px] font-medium", if(row.active, do: "text-tymeslot-500", else: "text-tymeslot-400")]}>
                {row.label}
              </span>
            </div>
          <% end %>
        </div>

        <%!-- Desktop: full grid --%>
        <div class="hidden sm:block overflow-x-auto">
          <div class="min-w-[800px] bg-tymeslot-50/50 rounded-token-3xl p-6 border-2 border-tymeslot-50">
            <div class="grid grid-cols-8 gap-2 text-xs sm:text-sm">
              <%!-- Header Row --%>
              <div class="font-black text-tymeslot-400 uppercase tracking-widest text-center py-4"></div>
              <%= for {day_name, _day_number} <- [{"Mon", 1}, {"Tue", 2}, {"Wed", 3}, {"Thu", 4}, {"Fri", 5}, {"Sat", 6}, {"Sun", 7}] do %>
                <div class="font-black text-tymeslot-700 text-center py-4 bg-white rounded-token-xl border-2 border-white shadow-sm">
                  {day_name}
                </div>
              <% end %>

              <%!-- Time Slots Grid --%>
              <%= for hour <- 6..22 do %>
                <%= for minute <- [0, 30] do %>
                  <div class="font-black text-tymeslot-400 text-right py-1 pr-4 text-token-2xs sm:text-xs uppercase tracking-tighter">
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
                          :available -> "background-color: #10b981; opacity: 0.8;"
                          :partial -> "background: linear-gradient(45deg, #10b981 50%, #f59e0b 50%); opacity: 0.8;"
                          :unavailable -> ""
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
        </div>

        <%!-- Legend --%>
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

  # Computes display data for a single mobile timeline row.
  defp mobile_row_data(%{
         is_available: true,
         start_time: %Time{} = start_time,
         end_time: %Time{} = end_time,
         breaks: breaks
       }) do
    start_min = time_to_minutes(start_time)
    end_min = time_to_minutes(end_time)

    break_segments =
      breaks
      |> Enum.map(fn b ->
        b_start = max(time_to_minutes(b.start_time), start_min)
        b_end = min(time_to_minutes(b.end_time), end_min)

        if b_end > b_start,
          do: %{
            left: bar_left(b_start),
            width: bar_width(b_start, b_end),
            label: b.label || "Break"
          }
      end)
      |> Enum.reject(&is_nil/1)

    %{
      active: true,
      left: bar_left(start_min),
      width: bar_width(start_min, end_min),
      label: "#{format_time_label(start_time)} – #{format_time_label(end_time)}",
      breaks: break_segments
    }
  end

  defp mobile_row_data(_row),
    do: %{active: false, left: 0, width: 0, label: "Unavailable", breaks: []}

  # Helper Functions

  defp time_to_minutes(%Time{hour: h, minute: m}), do: h * 60 + m

  defp bar_left(start_min),
    do: Float.round((start_min - @grid_start_minutes) / @grid_total_minutes * 100, 2)

  defp bar_width(start_min, end_min),
    do: Float.round((end_min - start_min) / @grid_total_minutes * 100, 2)

  defp format_time_label(%Time{hour: h, minute: m}) when h < 12,
    do: "#{h}:#{String.pad_leading(Integer.to_string(m), 2, "0")} AM"

  defp format_time_label(%Time{hour: 12, minute: m}),
    do: "12:#{String.pad_leading(Integer.to_string(m), 2, "0")} PM"

  defp format_time_label(%Time{hour: h, minute: m}) when h > 12,
    do: "#{h - 12}:#{String.pad_leading(Integer.to_string(m), 2, "0")} PM"

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
    slot_end = Time.add(slot_start, @slot_duration_minutes, :minute)

    slot_in_business_hours =
      Time.compare(slot_start, end_time) == :lt and Time.compare(slot_end, start_time) == :gt

    if slot_in_business_hours do
      check_breaks_for_slot(breaks, slot_start, slot_end)
    else
      {:unavailable, "Outside business hours"}
    end
  end

  defp check_breaks_for_slot(breaks, slot_start, slot_end) do
    overlapping_breaks = Enum.filter(breaks, &break_overlaps_slot?(&1, slot_start, slot_end))

    case overlapping_breaks do
      [] -> {:available, "Available for booking"}
      [break | _rest] -> get_break_status(break, slot_start, slot_end)
    end
  end

  defp break_overlaps_slot?(break, slot_start, slot_end) do
    Time.compare(break.start_time, slot_end) == :lt and
      Time.compare(break.end_time, slot_start) == :gt
  end

  defp get_break_status(break, slot_start, slot_end) do
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
