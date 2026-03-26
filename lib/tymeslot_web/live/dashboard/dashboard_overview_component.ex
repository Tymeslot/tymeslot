defmodule TymeslotWeb.Dashboard.DashboardOverviewComponent do
  @moduledoc """
  LiveView component that displays a dashboard overview with meeting statistics,
  upcoming meetings, and quick action links for managing scheduling settings.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Components.Icons.IconComponents

  @spec format_meeting_time(map(), String.t() | nil) :: String.t()

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    upcoming_meetings = get_in(assigns, [:shared_data, :upcoming_meetings]) || []
    {:ok, socket |> assign(assigns) |> assign(:upcoming_meetings, upcoming_meetings)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <.section_header
        icon={:home}
        title="Overview"
      />

      <%!-- Welcome Section --%>
      <div class="bg-gradient-to-br from-turquoise-600 via-cyan-600 to-blue-600 rounded-token-3xl p-8 lg:p-12 text-white shadow-2xl shadow-turquoise-500/20 relative overflow-hidden">
        <div class="absolute inset-0 bg-[radial-gradient(circle_at_30%_20%,rgba(255,255,255,0.15),transparent_50%)]"></div>
        <div class="relative z-10">
          <h1 class="text-4xl lg:text-5xl font-black mb-4 tracking-tight">
            Welcome back{if @profile.full_name, do: ", #{@profile.full_name}", else: ""}!
          </h1>
          <p class="text-xl text-white/90 font-medium max-w-2xl leading-relaxed">
            Here's an overview of your scheduling setup and recent activity. Everything looks great today!
          </p>
        </div>
      </div>

      <%!-- Dashboard Grid --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <%!-- Upcoming Meetings --%>
        <div class="card-glass h-full">
          <div class="flex items-center justify-between mb-8">
            <.section_header
              level={2}
              title="Upcoming Meetings"
              count={length(@upcoming_meetings)}
            />
            <.link
              patch={~p"/dashboard/meetings"}
              class="text-turquoise-600 hover:text-turquoise-700 font-bold text-token-sm transition-colors flex items-center gap-1 group"
            >
              View all <span class="group-hover:translate-x-1 transition-transform">→</span>
            </.link>
          </div>

          <%= if @upcoming_meetings == [] do %>
            <div class="text-center py-12 bg-tymeslot-50/50 rounded-token-2xl border-2 border-dashed border-tymeslot-100">
              <div class="w-16 h-16 bg-white rounded-token-2xl flex items-center justify-center mx-auto mb-4 shadow-sm">
                <IconComponents.icon name={:calendar} class="w-8 h-8 text-tymeslot-300" />
              </div>
              <p class="text-tymeslot-500 font-bold">No upcoming meetings scheduled yet.</p>
            </div>
          <% else %>
            <div class="space-y-4">
              <%= for meeting <- @upcoming_meetings do %>
                <.meeting_preview meeting={meeting} profile={@profile} />
              <% end %>
            </div>
          <% end %>
        </div>

    <%!-- Quick Actions --%>
        <div class="card-glass h-full">
          <.section_header
            level={2}
            title="Quick Actions"
            class="mb-8"
          />

          <div class="grid gap-4">
            <.action_link
              patch={~p"/dashboard/settings"}
              icon={:user}
              title="Profile Settings"
              description="Update your timezone and display name"
              color_class="bg-turquoise-50 text-turquoise-600"
            />

            <.action_link
              patch={~p"/dashboard/meeting-settings"}
              icon={:grid}
              title="Meeting Types"
              description="Configure your booking durations"
              color_class="bg-cyan-50 text-cyan-600"
            />

            <.action_link
              patch={~p"/dashboard/calendar"}
              icon={:calendar}
              title="Calendar Integration"
              description="Connect your external calendars"
              color_class="bg-blue-50 text-blue-600"
            />

            <.action_link
              patch={~p"/dashboard/video"}
              icon={:video}
              title="Video Integration"
              description="Set up your conferencing tools"
              color_class="bg-indigo-50 text-indigo-600"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp meeting_preview(assigns) do
    ~H"""
    <div class="flex items-center justify-between p-4 bg-tymeslot-50/50 rounded-token-2xl border-2 border-tymeslot-50 hover:bg-white hover:shadow-md transition-all group">
      <div class="flex-1">
        <div class="text-tymeslot-900 font-black tracking-tight group-hover:text-turquoise-700 transition-colors">
          {@meeting.title}
        </div>
        <div class="text-token-sm text-tymeslot-500 font-bold">
          {@meeting.attendee_name} • {format_meeting_time(@meeting, @profile.timezone)}
        </div>
      </div>
      <div class="flex-shrink-0">
        <span class="px-3 py-1 text-token-xs font-black bg-emerald-100 text-emerald-700 rounded-full uppercase tracking-wider">
          {@meeting.status}
        </span>
      </div>
    </div>
    """
  end

  attr :patch, :string, required: true
  attr :icon, :atom, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :color_class, :string, default: "bg-tymeslot-50 text-tymeslot-600"

  defp action_link(assigns) do
    ~H"""
    <.link patch={@patch} class="block group">
      <div class="flex items-center p-4 rounded-token-2xl bg-tymeslot-50/50 border-2 border-tymeslot-50 hover:bg-white hover:border-turquoise-100 hover:shadow-xl hover:shadow-turquoise-500/5 transition-all">
        <div class="flex-shrink-0 mr-4">
          <div class={["w-12 h-12 rounded-token-xl flex items-center justify-center transition-all shadow-sm", @color_class]}>
            <IconComponents.icon name={@icon} class="w-6 h-6" />
          </div>
        </div>
        <div class="flex-1 min-w-0">
          <div class="text-tymeslot-900 font-black tracking-tight group-hover:text-turquoise-700 transition-colors">
            {@title}
          </div>
          <div class="text-token-sm text-tymeslot-500 font-bold truncate group-hover:text-tymeslot-600 transition-colors">
            {@description}
          </div>
        </div>
        <div class="flex-shrink-0 ml-4">
          <div class="w-8 h-8 rounded-token-lg bg-white flex items-center justify-center border border-tymeslot-100 group-hover:border-turquoise-200 group-hover:bg-turquoise-50 transition-all">
            <svg
              class="w-4 h-4 text-tymeslot-400 group-hover:text-turquoise-600 transition-all transform group-hover:translate-x-0.5"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M9 5l7 7-7 7">
              </path>
            </svg>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  defp format_meeting_time(meeting, timezone) do
    cond do
      is_nil(meeting) or is_nil(Map.get(meeting, :start_time)) ->
        "Time TBD"

      is_nil(timezone) or timezone == "" ->
        "Time TBD"

      true ->
        try do
          start_time = DateTimeUtils.convert_to_timezone(meeting.start_time, timezone)
          date_str = Calendar.strftime(start_time, "%b %d")
          time_str = Calendar.strftime(start_time, "%-I:%M %p")
          "#{date_str} at #{time_str}"
        rescue
          _error -> "Time TBD"
        end
    end
  end
end
