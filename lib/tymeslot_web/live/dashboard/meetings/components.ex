defmodule TymeslotWeb.Live.Dashboard.Meetings.Components do
  @moduledoc false
  use Phoenix.Component

  alias Tymeslot.Utils.TimezoneUtils
  alias TymeslotWeb.Components.FlagHelpers
  alias TymeslotWeb.Live.Dashboard.Meetings.Helpers

  # Filter Tabs
  attr :active, :string, required: true
  attr :target, :any, required: true

  @spec filter_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def filter_tabs(assigns) do
    ~H"""
    <div class="flex bg-white/5 backdrop-blur-sm border border-purple-200/30 rounded-lg p-1 mb-6 max-w-fit">
      <button
        phx-click="filter_meetings"
        phx-value-filter="upcoming"
        phx-target={@target}
        class={[
          "flex items-center space-x-2 px-4 py-2 rounded-md text-sm font-medium transition-all duration-200",
          if(@active == "upcoming",
            do: "btn-primary",
            else: "btn-ghost text-gray-600 hover:text-gray-800"
          )
        ]}
      >
        <.icon name="upcoming" />
        <span>Upcoming</span>
      </button>
      <button
        phx-click="filter_meetings"
        phx-value-filter="past"
        phx-target={@target}
        class={[
          "flex items-center space-x-2 px-4 py-2 rounded-md text-sm font-medium transition-all duration-200",
          if(@active == "past",
            do: "btn-primary",
            else: "btn-ghost text-gray-600 hover:text-gray-800"
          )
        ]}
      >
        <.icon name="past" />
        <span>Past</span>
      </button>
      <button
        phx-click="filter_meetings"
        phx-value-filter="cancelled"
        phx-target={@target}
        class={[
          "flex items-center space-x-2 px-4 py-2 rounded-md text-sm font-medium transition-all duration-200",
          if(@active == "cancelled",
            do: "btn-primary",
            else: "btn-ghost text-gray-600 hover:text-gray-800"
          )
        ]}
      >
        <.icon name="cancelled" />
        <span>Cancelled</span>
      </button>
    </div>
    """
  end

  # Meetings List Entry
  attr :loading, :boolean, required: true
  attr :meetings, :list, required: true
  attr :filter, :string, required: true
  attr :profile, :any, required: false
  attr :cancelling_meeting, :any, required: false
  attr :sending_reschedule, :any, required: false
  attr :target, :any, required: true
  # Optional stream for efficient updates
  attr :meetings_stream, :any, required: false

  @spec meetings_list(map()) :: Phoenix.LiveView.Rendered.t()
  def meetings_list(assigns) do
    ~H"""
    <div>
      <%= if @loading do %>
        <.loading_spinner />
      <% else %>
        <%= if @meetings == [] do %>
          <.empty_state filter={@filter} />
        <% else %>
          <%= if @meetings_stream do %>
            <div class="space-y-4" id="meetings" phx-update="stream">
              <%= for {dom_id, meeting} <- @meetings_stream do %>
                <div id={dom_id}>
                  <.meeting_card
                    meeting={meeting}
                    profile={@profile}
                    cancelling_meeting={@cancelling_meeting}
                    sending_reschedule={@sending_reschedule}
                    target={@target}
                  />
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="space-y-4">
              <%= for meeting <- @meetings do %>
                <.meeting_card
                  meeting={meeting}
                  profile={@profile}
                  cancelling_meeting={@cancelling_meeting}
                  sending_reschedule={@sending_reschedule}
                  target={@target}
                />
              <% end %>
            </div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  # Meeting Card
  attr :meeting, :map, required: true
  attr :profile, :any, required: false
  attr :cancelling_meeting, :any, required: false
  attr :sending_reschedule, :any, required: false
  attr :target, :any, required: true

  @spec meeting_card(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_card(assigns) do
    ~H"""
    <div class="glass-card p-4 shadow-md hover:shadow-xl transition-shadow duration-200">
      <div class="flex flex-col lg:flex-row lg:items-start justify-between gap-4">
        <div class="flex-1">
          <div class="flex items-start justify-between mb-3">
            <div class="flex-1">
              <div class="flex items-center gap-2 flex-wrap">
                <h4 class="text-lg font-bold text-neutral-800">{@meeting.attendee_name}</h4>
                <%= if @meeting.attendee_company do %>
                  <span class="text-sm text-neutral-500">• {@meeting.attendee_company}</span>
                <% end %>
                <.status_badges meeting={@meeting} />
                <%= if @meeting.meeting_url do %>
                  <span class="inline-flex items-center gap-1.5 px-2.5 py-1 bg-blue-500/20 text-blue-400 text-xs font-medium rounded-full border border-blue-400/30">
                    <.icon name="video" /> Video
                  </span>
                <% end %>
              </div>
            </div>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
            <div class="flex items-center text-sm">
              <div class="w-8 h-8 rounded-lg bg-turquoise-100 flex items-center justify-center mr-2.5">
                <.icon name="calendar" class="text-turquoise-600" />
              </div>
              <span class="text-neutral-700 font-medium">
                {Helpers.format_meeting_date(
                  @meeting,
                  Helpers.get_meeting_timezone(@meeting, @profile)
                )}
              </span>
            </div>

            <div class="flex items-center text-sm">
              <div class="w-8 h-8 rounded-lg bg-purple-100 flex items-center justify-center mr-2.5">
                <.icon name="clock" class="text-purple-600" />
              </div>
              <span class="text-neutral-700 font-medium">
                {Helpers.format_meeting_time(
                  @meeting,
                  Helpers.get_meeting_timezone(@meeting, @profile)
                )}
                <span class="text-neutral-500">({@meeting.duration} min)</span>
              </span>
            </div>

            <div class="flex items-center text-sm">
              <div class="w-8 h-8 rounded-lg bg-blue-100 flex items-center justify-center mr-2.5">
                <.icon name="email" class="text-blue-600" />
              </div>
              <a
                href={"mailto:#{@meeting.attendee_email}"}
                class="text-neutral-700 hover:text-turquoise-600 hover:underline transition-colors truncate font-medium"
                title={@meeting.attendee_email}
              >
                {@meeting.attendee_email}
              </a>
            </div>

            <%= if @profile && @profile.timezone do %>
              <div class="flex items-center text-sm">
                <div class="w-8 h-8 rounded-lg bg-orange-100 flex items-center justify-center mr-2.5">
                  <%= if TimezoneUtils.get_country_code_for_timezone(@profile.timezone) do %>
                    <FlagHelpers.timezone_flag
                      timezone={@profile.timezone}
                      class="w-5 h-4 rounded-sm"
                    />
                  <% else %>
                    <.icon name="globe" class="text-orange-600" />
                  <% end %>
                </div>
                <span class="text-neutral-700 font-medium">
                  {TimezoneUtils.format_timezone(@profile.timezone)}
                </span>
              </div>
            <% end %>
          </div>

          <%= if @meeting.description && @meeting.description != "" do %>
            <div class="mt-3 p-3 bg-gradient-to-r from-amber-50 to-yellow-50 rounded-lg border border-amber-200">
              <div class="flex items-start gap-2.5">
                <div class="w-6 h-6 rounded bg-amber-200/50 flex items-center justify-center flex-shrink-0">
                  <.icon name="note" class="text-amber-700" />
                </div>
                <div class="flex-1">
                  <p class="text-xs font-semibold text-amber-800 mb-0.5">Meeting Notes</p>
                  <p class="text-sm text-amber-900">{@meeting.description}</p>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <div class="flex lg:flex-col gap-1.5 flex-shrink-0 lg:items-stretch lg:w-[120px]">
          <%= if @meeting.status != "cancelled" && @meeting.status != "reschedule_requested" && !Helpers.past_meeting?(@meeting) do %>
            <%= if @meeting.meeting_url do %>
              <a
                href={@meeting.meeting_url}
                target="_blank"
                rel="noopener noreferrer"
                class="btn btn-sm btn-primary text-center w-full"
              >
                <.icon name="video" class="mr-1.5" /> Join
              </a>
            <% end %>

            <button
              phx-click="show_reschedule_modal"
              phx-value-id={@meeting.id}
              phx-target={@target}
              disabled={!Helpers.can_reschedule?(@meeting)}
              title={Helpers.action_tooltip(@meeting, :reschedule)}
              class={[
                "btn btn-sm text-center w-full",
                if(Helpers.can_reschedule?(@meeting),
                  do: "btn-secondary",
                  else: "btn-disabled opacity-50 cursor-not-allowed"
                )
              ]}
            >
              <.icon name="swap" class="mr-1.5" /> Reschedule
            </button>

            <button
              id={"cancel-meeting-#{@meeting.id}"}
              phx-click="show_cancel_modal"
              phx-value-id={@meeting.id}
              phx-target={@target}
              disabled={@cancelling_meeting == @meeting.id || !Helpers.can_cancel?(@meeting)}
              title={Helpers.action_tooltip(@meeting, :cancel)}
              class={[
                "btn btn-sm text-center w-full",
                if(Helpers.can_cancel?(@meeting),
                  do: "btn-danger",
                  else: "btn-disabled opacity-50 cursor-not-allowed"
                )
              ]}
            >
              <%= if @cancelling_meeting == @meeting.id do %>
                <.spinner class="mr-1.5" /> Cancelling
              <% else %>
                <.icon name="x" class="mr-1.5" /> Cancel
              <% end %>
            </button>
          <% else %>
            <div class="hidden sm:block sm:min-w-[100px]">&nbsp;</div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Subcomponents
  defp status_badges(assigns) do
    ~H"""
    <%= if @meeting.status == "cancelled" do %>
      <span class="inline-flex items-center gap-1.5 px-2.5 py-1 bg-red-500/20 text-red-400 text-xs font-medium rounded-full border border-red-400/30">
        <.icon name="x" /> Cancelled
      </span>
    <% else %>
      <%= if @meeting.status == "reschedule_requested" do %>
        <span class="inline-flex items-center gap-1.5 px-2.5 py-1 bg-amber-500/30 text-amber-700 text-xs font-medium rounded-full border border-amber-500/50">
          <.icon name="clock" /> Reschedule Requested
        </span>
      <% else %>
        <%= if Helpers.past_meeting?(@meeting) do %>
          <span class="inline-flex items-center gap-1.5 px-2.5 py-1 bg-gray-500/20 text-gray-400 text-xs font-medium rounded-full border border-gray-400/30">
            <.icon name="check" /> Completed
          </span>
        <% else %>
          <span class="inline-flex items-center gap-1.5 px-2.5 py-1 bg-turquoise-500/20 text-turquoise-400 text-xs font-medium rounded-full border border-turquoise-400/30">
            <.icon name="calendar" /> Scheduled
          </span>
        <% end %>
      <% end %>
    <% end %>
    """
  end

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="text-center py-12">
        <div class="w-16 h-16 mx-auto mb-4 rounded-full bg-turquoise-100/20 flex items-center justify-center">
          <.icon name="calendar" class="w-8 h-8 text-turquoise-600" />
        </div>
        <p class="text-neutral-600 font-medium">
          <%= case @filter do %>
            <% "upcoming" -> %>
              No upcoming meetings scheduled
            <% "past" -> %>
              No past meetings found
            <% "cancelled" -> %>
              No cancelled meetings
          <% end %>
        </p>
        <p class="text-sm text-neutral-500 mt-2">
          <%= case @filter do %>
            <% "upcoming" -> %>
              New meetings will appear here when scheduled
            <% "past" -> %>
              Completed meetings will be shown here
            <% "cancelled" -> %>
              Cancelled meetings will be listed here
          <% end %>
        </p>
      </div>
    </div>
    """
  end

  @spec loading_spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def loading_spinner(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="flex items-center justify-center py-12">
        <.spinner />
      </div>
    </div>
    """
  end

  @spec info_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def info_panel(assigns) do
    ~H"""
    <div class="mt-8 card-glass">
      <div class="flex items-start space-x-3">
        <div class="flex-shrink-0">
          <.icon name="info" class="w-5 h-5 text-turquoise-600 mt-0.5" />
        </div>
        <div class="flex-1">
          <h3 class="text-base font-semibold text-neutral-800 mb-2">Meeting Management</h3>
          <p class="text-sm text-neutral-600 mb-3">
            Manage all your scheduled meetings in one place. Filter by status and take quick actions on your appointments.
          </p>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mt-4">
            <div class="flex items-start space-x-2">
              <.icon name="swap" class="w-4 h-4 text-turquoise-600 mt-0.5 flex-shrink-0" />
              <div>
                <p class="text-sm font-medium text-neutral-700">Reschedule</p>
                <p class="text-xs text-neutral-500">Change meeting times</p>
              </div>
            </div>
            <div class="flex items-start space-x-2">
              <.icon name="x" class="w-4 h-4 text-turquoise-600 mt-0.5 flex-shrink-0" />
              <div>
                <p class="text-sm font-medium text-neutral-700">Cancel</p>
                <p class="text-xs text-neutral-500">With auto notifications</p>
              </div>
            </div>
            <div class="flex items-start space-x-2">
              <.icon name="video" class="w-4 h-4 text-turquoise-600 mt-0.5 flex-shrink-0" />
              <div>
                <p class="text-sm font-medium text-neutral-700">Join Video</p>
                <p class="text-xs text-neutral-500">Quick meeting access</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Simple icon set matching existing SVGs
  attr :name, :string, required: true
  attr :class, :string, default: ""

  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(assigns) do
    ~H"""
    <%= case @name do %>
      <% "upcoming" -> %>
        <svg class={"w-4 h-4 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
          />
        </svg>
      <% "past" -> %>
        <svg class={"w-4 h-4 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
          />
        </svg>
      <% "cancelled" -> %>
        <svg class={"w-4 h-4 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M6 18L18 6M6 6l12 12"
          />
        </svg>
      <% "video" -> %>
        <svg class={"w-4 h-4 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"
          />
        </svg>
      <% "calendar" -> %>
        <svg class={"w-4 h-4 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
          />
        </svg>
      <% "clock" -> %>
        <svg class={"w-4 h-4 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
          />
        </svg>
      <% "email" -> %>
        <svg class={"w-4 h-4 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
          />
        </svg>
      <% "globe" -> %>
        <svg class={"w-4 h-4 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M3.055 11H5a2 2 0 012 2v1a2 2 0 002 2 2 2 0 012 2v2.945M8 3.935V5.5A2.5 2.5 0 0010.5 8h.5a2 2 0 012 2 2 2 0 104 0 2 2 0 012-2h1.064M15 20.488V18a2 2 0 012-2h3.064M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
          />
        </svg>
      <% "note" -> %>
        <svg class={"w-3.5 h-3.5 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
          />
        </svg>
      <% "check" -> %>
        <svg class={"w-3.5 h-3.5 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
          />
        </svg>
      <% "info" -> %>
        <svg class={"w-5 h-5 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
          />
        </svg>
      <% "swap" -> %>
        <svg class={"w-4 h-4 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4"
          />
        </svg>
      <% "x" -> %>
        <svg class={"w-4 h-4 #{@class}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M6 18L18 6M6 6l12 12"
          />
        </svg>
    <% end %>
    """
  end

  # Simple spinner
  attr :class, :string, default: ""

  @spec spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def spinner(assigns) do
    ~H"""
    <svg class={"animate-spin h-8 w-8 text-turquoise-600 #{@class}"} fill="none" viewBox="0 0 24 24">
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
      </circle>
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      >
      </path>
    </svg>
    """
  end
end
