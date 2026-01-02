defmodule TymeslotWeb.Dashboard.DashboardOverviewComponent do
  @moduledoc """
  LiveView component that displays a dashboard overview with meeting statistics,
  upcoming meetings, and quick action links for managing scheduling settings.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Components.Icons.IconComponents

  @spec format_meeting_time(map(), String.t() | nil) :: String.t()

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Welcome Section -->
      <div class="mb-8">
        <h1 class="text-3xl font-bold text-gray-800 mb-2">
          Welcome back{if @profile.full_name, do: ", #{@profile.full_name}", else: ""}!
        </h1>
        <p class="text-gray-600">
          Here's an overview of your scheduling setup and recent activity.
        </p>
      </div>
      
    <!-- Quick Actions -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <!-- Recent Meetings -->
        <div class="card-glass">
          <div class="flex items-center justify-between mb-4">
            <div class="flex items-center space-x-2">
              <h2 class="text-xl font-semibold text-gray-800">Upcoming Meetings</h2>
              <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-teal-100 text-teal-800">
                {length(Map.get(@shared_data || %{}, :upcoming_meetings, []))}
              </span>
            </div>
            <.link
              patch={~p"/dashboard/meetings"}
              class="text-teal-600 hover:text-teal-700 text-sm transition-colors"
            >
              View all →
            </.link>
          </div>

          <%= if Map.get(@shared_data || %{}, :upcoming_meetings, []) == [] do %>
            <div class="text-center py-6 text-gray-500">
              <svg
                class="w-12 h-12 mx-auto mb-3 opacity-50"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
                />
              </svg>
              <p>No upcoming meetings</p>
            </div>
          <% else %>
            <div class="space-y-3">
              <%= for meeting <- Map.get(@shared_data || %{}, :upcoming_meetings, []) do %>
                <.meeting_preview meeting={meeting} profile={@profile} />
              <% end %>
            </div>
          <% end %>
        </div>
        
    <!-- Quick Actions -->
        <div class="card-glass">
          <h2 class="text-xl font-semibold text-gray-800 mb-4">Quick Actions</h2>

          <div class="space-y-3">
            <.action_link
              patch={~p"/dashboard/settings"}
              icon="user"
              title="Profile Settings"
              description="Update your timezone, display name, and scheduling preferences"
            />

            <.action_link
              patch={~p"/dashboard/meeting-settings"}
              icon="grid"
              title="Meeting Types"
              description="Configure available meeting durations and types"
            />

            <.action_link
              patch={~p"/dashboard/calendar"}
              icon="calendar"
              title="Calendar Integration"
              description="Connect your calendar to check availability"
            />

            <.action_link
              patch={~p"/dashboard/video"}
              icon="video"
              title="Video Integration"
              description="Set up video conferencing for meetings"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp meeting_preview(assigns) do
    ~H"""
    <div class="flex items-center justify-between p-3 bg-white/5 rounded-lg">
      <div class="flex-1">
        <div class="text-gray-800 font-medium">{@meeting.title}</div>
        <div class="text-sm text-gray-600">
          {@meeting.attendee_name} • {format_meeting_time(@meeting, @profile.timezone)}
        </div>
      </div>
      <div class="flex-shrink-0">
        <span class="px-2 py-1 text-xs bg-green-600 text-white rounded-full">
          {String.capitalize(@meeting.status)}
        </span>
      </div>
    </div>
    """
  end

  defp action_link(assigns) do
    ~H"""
    <.link patch={@patch} class="block">
      <div class="flex items-center p-3 rounded-lg hover:bg-white/5 transition-colors group">
        <div class="flex-shrink-0 mr-3">
          <div class="w-8 h-8 bg-teal-600/20 rounded-full flex items-center justify-center group-hover:bg-teal-600/30 transition-colors">
            <IconComponents.icon name={@icon} class="w-5 h-5 text-teal-600" />
          </div>
        </div>
        <div class="flex-1">
          <div class="text-gray-800 font-medium group-hover:text-teal-700 transition-colors">
            {@title}
          </div>
          <div class="text-sm text-gray-600 group-hover:text-gray-700 transition-colors">
            {@description}
          </div>
        </div>
        <div class="flex-shrink-0">
          <svg
            class="w-4 h-4 text-gray-500 group-hover:text-teal-600 transition-colors"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7">
            </path>
          </svg>
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
          _ -> "Time TBD"
        end
    end
  end
end
