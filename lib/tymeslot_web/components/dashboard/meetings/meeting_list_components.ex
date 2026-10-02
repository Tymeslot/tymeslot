defmodule TymeslotWeb.Components.Dashboard.Meetings.MeetingListComponents do
  @moduledoc """
  UI components for displaying and filtering meetings in the dashboard.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Dashboard.Meetings.MeetingCard

  # Filter Tabs
  attr :active, :string, required: true
  attr :target, :any, required: true
  attr :awaiting_approval_count, :integer, default: 0

  @spec filter_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def filter_tabs(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1 bg-white border-2 border-tymeslot-50 rounded-[1.25rem] p-1.5 shadow-sm w-fit max-w-full">
      <.filter_tab_button
        active={@active == "upcoming"}
        filter="upcoming"
        label={dgettext("dashboard_bookings", "Upcoming")}
        icon="hero-clock"
        target={@target}
      />
      <.filter_tab_button
        active={@active == "past"}
        filter="past"
        label={dgettext("dashboard_bookings", "Past")}
        icon="hero-calendar-days"
        target={@target}
      />
      <.filter_tab_button
        active={@active == "cancelled"}
        filter="cancelled"
        label={dgettext("dashboard_bookings", "Cancelled")}
        icon="hero-x-mark"
        target={@target}
      />
      <%!-- Only shown once there is something to answer: a host who requires no
            approvals should never see a tab that is permanently empty. --%>
      <.filter_tab_button
        :if={@awaiting_approval_count > 0 or @active == "awaiting_approval"}
        active={@active == "awaiting_approval"}
        filter="awaiting_approval"
        label={dgettext("dashboard_bookings", "Requests")}
        icon="hero-inbox-arrow-down"
        count={@awaiting_approval_count}
        target={@target}
      />
    </div>
    """
  end

  attr :active, :boolean, required: true
  attr :filter, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :target, :any, required: true
  attr :count, :integer, default: 0

  defp filter_tab_button(assigns) do
    ~H"""
    <button
      phx-click="filter_meetings"
      phx-value-filter={@filter}
      phx-target={@target}
      class={[
        "flex items-center gap-2 px-3 sm:px-6 py-2.5 rounded-token-xl text-token-sm font-black transition-all duration-300",
        if(@active,
          do:
            "bg-linear-to-br from-turquoise-600 to-cyan-600 text-white shadow-lg shadow-turquoise-500/20",
          else: "text-tymeslot-500 hover:text-turquoise-600 hover:bg-turquoise-50"
        )
      ]}
    >
      <CoreComponents.icon
        name={@icon}
        class={"hidden sm:block shrink-0 #{if @active, do: "text-white/90"}"}
      />
      <span>{@label}</span>
      <span
        :if={@count > 0}
        class={[
          "ml-1 inline-flex items-center justify-center min-w-[1.375rem] h-5.5 px-1.5 rounded-full text-token-xs font-black tabular-nums",
          if(@active, do: "bg-white/25 text-white", else: "bg-amber-100 text-amber-700")
        ]}
      >
        {@count}
      </span>
    </button>
    """
  end

  # Meetings List
  attr :loading, :boolean, required: true
  attr :is_empty, :boolean, required: true
  attr :filter, :string, required: true
  attr :profile, :any, required: false
  attr :time_format, :string, required: true
  attr :cancelling_meeting, :any, required: false
  attr :sending_reschedule, :any, required: false
  attr :answering_request, :any, default: nil
  attr :target, :any, required: true
  attr :meetings_stream, :any, required: true

  @spec meetings_list(map()) :: Phoenix.LiveView.Rendered.t()
  def meetings_list(assigns) do
    ~H"""
    <div>
      <CoreComponents.loading_card
        :if={@loading}
        label={dgettext("dashboard_bookings", "Loading meetings")}
      />
      <.no_meetings :if={!@loading and @is_empty} filter={@filter} />
      <div :if={!@loading and !@is_empty} class="space-y-4" id="meetings" phx-update="stream">
        <div :for={{dom_id, meeting} <- @meetings_stream} id={dom_id}>
          <MeetingCard.meeting_card
            meeting={meeting}
            profile={@profile}
            time_format={@time_format}
            cancelling_meeting={@cancelling_meeting}
            sending_reschedule={@sending_reschedule}
            answering_request={@answering_request}
            target={@target}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :has_more, :boolean, required: true
  attr :loading_more, :boolean, required: true
  attr :target, :any, required: true

  @doc """
  The button that pages further into the list.

  Lives here rather than in the dashboard component's own `render/1` so that
  everything the meetings list draws is in one module — and so that module
  stays inside the project's size limit.
  """
  @spec load_more(map()) :: Phoenix.LiveView.Rendered.t()
  def load_more(assigns) do
    ~H"""
    <div :if={@has_more} class="mt-10 text-center">
      <CoreComponents.loading_button
        variant={:secondary}
        size={:lg}
        phx-click="load_more"
        phx-target={@target}
        loading={@loading_more}
        loading_text={dgettext("dashboard_bookings", "Loading...")}
      >
        {dgettext("dashboard_bookings", "Load more meetings")}
      </CoreComponents.loading_button>
    </div>
    """
  end

  attr :filter, :string, required: true

  defp no_meetings(assigns) do
    ~H"""
    <CoreComponents.empty_state
      icon="hero-calendar-days"
      size={:lg}
      heading={:h3}
      title={no_meetings_title(@filter)}
      description={no_meetings_description(@filter)}
    />
    """
  end

  defp no_meetings_title("upcoming"), do: dgettext("dashboard_bookings", "No upcoming meetings")
  defp no_meetings_title("past"), do: dgettext("dashboard_bookings", "No past meetings")
  defp no_meetings_title("cancelled"), do: dgettext("dashboard_bookings", "No cancelled meetings")

  defp no_meetings_title("awaiting_approval"),
    do: dgettext("dashboard_bookings", "Nothing waiting on you")

  defp no_meetings_description("upcoming"),
    do:
      dgettext("dashboard_bookings", "Your upcoming appointments will appear here automatically.")

  defp no_meetings_description("past"),
    do: dgettext("dashboard_bookings", "You haven't had any meetings in this period yet.")

  defp no_meetings_description("cancelled"),
    do: dgettext("dashboard_bookings", "You don't have any cancelled appointments to show.")

  defp no_meetings_description("awaiting_approval"),
    do:
      dgettext(
        "dashboard_bookings",
        "Booking requests you haven't answered yet will appear here."
      )

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
            tone={:brand}
          />
          <.info_card
            icon="hero-x-mark"
            title={dgettext("dashboard_bookings", "Cancel")}
            description={dgettext("dashboard_bookings", "With auto notifications")}
            tone={:danger}
          />
          <.info_card
            icon="hero-video-camera"
            title={dgettext("dashboard_bookings", "Join Video")}
            description={dgettext("dashboard_bookings", "Quick meeting access")}
            tone={:info}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :tone, :atom, required: true

  defp info_card(assigns) do
    ~H"""
    <div class="p-5 rounded-token-2xl bg-white border-2 border-tymeslot-50 shadow-sm hover:border-turquoise-100 transition-all hover:shadow-md">
      <CoreComponents.detail_line variant={:tile} tone={@tone} icon={@icon} label={@title}>
        {@description}
      </CoreComponents.detail_line>
    </div>
    """
  end
end
