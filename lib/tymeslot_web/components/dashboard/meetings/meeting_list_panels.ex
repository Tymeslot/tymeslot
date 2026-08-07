defmodule TymeslotWeb.Components.Dashboard.Meetings.MeetingListPanels do
  @moduledoc """
  List-level panels for the dashboard meetings page.

  The loading, empty and informational states that frame the meetings list,
  as opposed to the meeting cards themselves. Split out of
  `MeetingListComponents` so that module stays about rendering a meeting and
  its guests, and so neither grows past the module size limit as the two
  concerns evolve independently.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents

  attr :filter, :string, required: true

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div class="card-glass py-20">
      <div class="text-center max-w-sm mx-auto">
        <div class="w-24 h-24 mx-auto mb-8 rounded-token-3xl bg-tymeslot-50 flex items-center justify-center border-2 border-tymeslot-100 shadow-sm transition-transform hover:scale-110 hover:rotate-3 duration-500">
          <CoreComponents.icon name="hero-calendar-days" class="w-12 h-12 text-tymeslot-300" />
        </div>
        <h3 class="text-token-2xl font-black text-tymeslot-900 tracking-tight mb-3">
          <%= case @filter do %>
            <% "upcoming" -> %>
              {dgettext("dashboard_bookings", "No upcoming meetings")}
            <% "past" -> %>
              {dgettext("dashboard_bookings", "No past meetings")}
            <% "cancelled" -> %>
              {dgettext("dashboard_bookings", "No cancelled meetings")}
          <% end %>
        </h3>
        <p class="text-tymeslot-500 font-medium text-lg leading-relaxed">
          <%= case @filter do %>
            <% "upcoming" -> %>
              {dgettext(
                "dashboard_bookings",
                "Your upcoming appointments will appear here automatically."
              )}
            <% "past" -> %>
              {dgettext("dashboard_bookings", "You haven't had any meetings in this period yet.")}
            <% "cancelled" -> %>
              {dgettext(
                "dashboard_bookings",
                "You don't have any cancelled appointments to show."
              )}
          <% end %>
        </p>
      </div>
    </div>
    """
  end

  @doc "Displays a loading spinner inside a card."
  @spec loading_spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def loading_spinner(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="flex items-center justify-center py-12">
        <CoreComponents.spinner class="h-8 w-8 text-turquoise-600" />
      </div>
    </div>
    """
  end

  @doc "Displays an informational panel about meeting management features."
  @spec info_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def info_panel(assigns) do
    ~H"""
    <div class="mt-12 card-glass p-8 lg:p-12 relative overflow-hidden group/info">
      <div class="absolute top-0 right-0 -mr-16 -mt-16 w-64 h-64 bg-turquoise-500/5 rounded-full blur-3xl transition-colors group-hover/info:bg-turquoise-500/10">
      </div>

      <div class="flex flex-col lg:flex-row gap-12 relative z-10">
        <div class="flex-1">
          <CoreComponents.section_header
            level={2}
            icon="hero-calendar-days"
            title={dgettext("dashboard_bookings", "Meeting Management")}
            class="mb-6"
          />

          <p class="text-tymeslot-500 font-bold text-lg leading-relaxed max-w-2xl mb-8">
            {dgettext(
              "dashboard_bookings",
              "Manage all your scheduled meetings in one place. Filter by status and take quick actions on your appointments."
            )}
          </p>

          <div class="flex flex-wrap gap-4">
            <span class="inline-flex items-center gap-2 px-4 py-2 bg-tymeslot-50 text-tymeslot-600 rounded-token-xl text-token-sm font-black border border-tymeslot-100 shadow-sm">
              <div class="w-2 h-2 rounded-full bg-turquoise-500"></div>
              {dgettext("dashboard_bookings", "Real-time updates")}
            </span>
            <span class="inline-flex items-center gap-2 px-4 py-2 bg-tymeslot-50 text-tymeslot-600 rounded-token-xl text-token-sm font-black border border-tymeslot-100 shadow-sm">
              <div class="w-2 h-2 rounded-full bg-cyan-500"></div>
              {dgettext("dashboard_bookings", "Auto-notifications")}
            </span>
          </div>
        </div>

        <div class="lg:w-80 space-y-4">
          <.info_card
            icon="hero-arrows-right-left"
            title={dgettext("dashboard_bookings", "Reschedule")}
            description={dgettext("dashboard_bookings", "Change meeting times")}
            color="turquoise"
          />
          <.info_card
            icon="hero-x-mark"
            title={dgettext("dashboard_bookings", "Cancel")}
            description={dgettext("dashboard_bookings", "With auto notifications")}
            color="red"
          />
          <.info_card
            icon="hero-video-camera"
            title={dgettext("dashboard_bookings", "Join Video")}
            description={dgettext("dashboard_bookings", "Quick meeting access")}
            color="blue"
          />
        </div>
      </div>
    </div>
    """
  end

  defp info_card(assigns) do
    ~H"""
    <div class="p-5 rounded-token-2xl bg-white border-2 border-tymeslot-50 shadow-sm hover:border-turquoise-100 transition-all hover:shadow-md group/item">
      <div class="flex items-center gap-4">
        <div class={[
          "w-10 h-10 rounded-token-xl flex items-center justify-center transition-colors",
          case @color do
            "turquoise" -> "bg-turquoise-50 group-hover/item:bg-turquoise-100 text-turquoise-600"
            "red" -> "bg-red-50 group-hover/item:bg-red-100 text-red-500"
            "blue" -> "bg-blue-50 group-hover/item:bg-blue-100 text-blue-600"
            _other -> "bg-tymeslot-50 group-hover/item:bg-tymeslot-100 text-tymeslot-600"
          end
        ]}>
          <CoreComponents.icon name={@icon} class="w-5 h-5" />
        </div>
        <div>
          <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mb-0.5">
            {@title}
          </p>
          <p class="text-tymeslot-700 font-bold">{@description}</p>
        </div>
      </div>
    </div>
    """
  end
end
