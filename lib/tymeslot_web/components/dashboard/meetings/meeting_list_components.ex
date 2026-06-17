defmodule TymeslotWeb.Components.Dashboard.Meetings.MeetingListComponents do
  @moduledoc """
  UI components for displaying and filtering meetings in the dashboard.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Meetings
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers
  alias TymeslotWeb.Components.Icons.IconComponents, as: Icons

  # Filter Tabs
  attr :active, :string, required: true
  attr :target, :any, required: true

  @spec filter_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def filter_tabs(assigns) do
    ~H"""
    <div class="flex bg-white border-2 border-tymeslot-50 rounded-[1.25rem] p-1.5 shadow-sm max-w-fit">
      <.filter_tab_button
        active={@active == "upcoming"}
        filter="upcoming"
        label="Upcoming"
        icon={:clock}
        target={@target}
      />
      <.filter_tab_button
        active={@active == "past"}
        filter="past"
        label="Past"
        icon={:calendar}
        target={@target}
      />
      <.filter_tab_button
        active={@active == "cancelled"}
        filter="cancelled"
        label="Cancelled"
        icon={:x_mark}
        target={@target}
      />
    </div>
    """
  end

  attr :active, :boolean, required: true
  attr :filter, :string, required: true
  attr :label, :string, required: true
  attr :icon, :atom, required: true
  attr :target, :any, required: true

  defp filter_tab_button(assigns) do
    ~H"""
    <button
      phx-click="filter_meetings"
      phx-value-filter={@filter}
      phx-target={@target}
      class={[
        "flex items-center space-x-2 px-6 py-2.5 rounded-token-xl text-token-sm font-black transition-all duration-300",
        if(@active,
          do: "bg-gradient-to-br from-turquoise-600 to-cyan-600 text-white shadow-lg shadow-turquoise-500/20",
          else: "text-tymeslot-500 hover:text-turquoise-600 hover:bg-turquoise-50"
        )
      ]}
    >
      <Icons.icon name={@icon} class={if @active, do: "text-white/90", else: ""} />
      <span>{@label}</span>
    </button>
    """
  end

  # Meetings List
  attr :loading, :boolean, required: true
  attr :is_empty, :boolean, required: true
  attr :filter, :string, required: true
  attr :profile, :any, required: false
  attr :cancelling_meeting, :any, required: false
  attr :sending_reschedule, :any, required: false
  attr :target, :any, required: true
  attr :meetings_stream, :any, required: true

  @spec meetings_list(map()) :: Phoenix.LiveView.Rendered.t()
  def meetings_list(assigns) do
    ~H"""
    <div>
      <.loading_spinner :if={@loading} />
      <.empty_state :if={!@loading and @is_empty} filter={@filter} />
      <div :if={!@loading and !@is_empty} class="space-y-4" id="meetings" phx-update="stream">
        <div :for={{dom_id, meeting} <- @meetings_stream} id={dom_id}>
          <.meeting_card
            meeting={meeting}
            profile={@profile}
            cancelling_meeting={@cancelling_meeting}
            sending_reschedule={@sending_reschedule}
            target={@target}
          />
        </div>
      </div>
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
    <div class="card-glass hover:bg-white hover:border-turquoise-100 hover:shadow-2xl hover:shadow-turquoise-500/5 group/card">
      <.calendar_sync_banner
        :if={
          @meeting.calendar_sync_status in ["externally_deleted", "externally_modified"] and
            is_nil(@meeting.calendar_sync_status_dismissed_at)
        }
        meeting={@meeting}
        target={@target}
      />
      <div class="flex flex-col lg:flex-row lg:items-center justify-between gap-8">
        <div class="flex-1">
          <div class="flex items-center gap-3 flex-wrap mb-6">
            <h4 class="text-token-2xl font-black text-tymeslot-900 tracking-tight group-hover/card:text-turquoise-700 transition-colors">
              {@meeting.attendee_name}
            </h4>
            <span :if={@meeting.attendee_company} class="text-token-sm font-bold text-tymeslot-400 bg-tymeslot-50 px-3 py-1 rounded-token-lg">
              {@meeting.attendee_company}
            </span>
            <.status_badges meeting={@meeting} />
            <span :if={@meeting.meeting_url} class="inline-flex items-center gap-1.5 px-3 py-1 bg-cyan-50 text-cyan-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-cyan-100 shadow-sm">
              <Icons.icon name={:video} class="w-3.5 h-3.5" /> Video Call
            </span>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div class="flex items-center gap-4">
              <div class="w-12 h-12 rounded-token-2xl bg-turquoise-50 flex items-center justify-center shadow-sm border border-turquoise-100 transition-transform group-hover/card:scale-110">
                <Icons.icon name={:calendar} class="w-6 h-6 text-turquoise-600" />
              </div>
              <div>
                <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mb-0.5">
                  Date & Time
                </p>
                <p class="text-tymeslot-700 font-bold">
                  {Helpers.format_meeting_date(
                    @meeting,
                    Helpers.get_meeting_timezone(@meeting, @profile)
                  )}
                  <span class="text-turquoise-600 ml-1">
                    {Helpers.format_meeting_time(
                      @meeting,
                      Helpers.get_meeting_timezone(@meeting, @profile)
                    )}
                  </span>
                </p>
              </div>
            </div>

            <div class="flex items-center gap-4">
              <div class="w-12 h-12 rounded-token-2xl bg-blue-50 flex items-center justify-center shadow-sm border border-blue-100 transition-transform group-hover/card:scale-110">
                <Icons.icon name={:envelope} class="w-6 h-6 text-blue-600" />
              </div>
              <div>
                <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mb-0.5">
                  Attendee Email
                </p>
                <a
                  href={"mailto:#{@meeting.attendee_email}"}
                  class="text-tymeslot-700 hover:text-turquoise-600 transition-colors font-bold"
                >
                  {@meeting.attendee_email}
                </a>
              </div>
            </div>
          </div>

          <div
            :if={guest_list(@meeting) != []}
            class="mt-8 p-5 bg-tymeslot-50/50 rounded-token-2xl border-2 border-tymeslot-50"
          >
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-4">
                <div class="w-8 h-8 rounded-token-lg bg-white shadow-sm flex items-center justify-center flex-shrink-0 border border-tymeslot-100">
                  <CoreComponents.icon name="hero-user-group" class="w-4 h-4 text-tymeslot-400" />
                </div>
                <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest">
                  {gettext("Guests")}
                </p>
              </div>
              <span class="text-token-sm font-bold text-tymeslot-500">
                {guest_summary_label(@meeting)}
              </span>
            </div>
            <ul class="space-y-2.5">
              <li
                :for={guest <- guest_list(@meeting)}
                class="flex items-center justify-between gap-3"
              >
                <span class="flex items-center gap-2.5 min-w-0">
                  <span class="flex h-7 w-7 flex-none items-center justify-center rounded-token-full bg-turquoise-100 text-token-xs font-bold uppercase text-turquoise-700">
                    {guest_initial(guest)}
                  </span>
                  <span class="truncate text-token-sm font-medium text-tymeslot-700">
                    {guest.name || guest.email}
                  </span>
                </span>
                <.guest_status_badge status={guest.status} />
              </li>
            </ul>
          </div>

          <div :if={@meeting.description && @meeting.description != ""} class="mt-8 p-5 bg-tymeslot-50/50 rounded-token-2xl border-2 border-tymeslot-50 flex gap-4 items-start">
            <div class="w-8 h-8 rounded-token-lg bg-white shadow-sm flex items-center justify-center flex-shrink-0 border border-tymeslot-100">
              <Icons.icon name={:pencil_square} class="w-4 h-4 text-tymeslot-400" />
            </div>
            <div class="flex-1">
              <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mb-1">
                Meeting Notes
              </p>
              <p class="text-tymeslot-600 font-medium leading-relaxed">{@meeting.description}</p>
            </div>
          </div>

          <% displayable_fields =
            Enum.filter(@meeting.custom_fields_snapshot, fn field ->
              @meeting.custom_field_answers[field["id"]]
              |> then(&AnswerRenderer.render(field, &1))
              |> Kernel.!=("")
            end) %>
          <div
            :if={displayable_fields != []}
            class="mt-8 p-5 bg-tymeslot-50/50 rounded-token-2xl border-2 border-tymeslot-50"
          >
            <div class="flex gap-4 items-start mb-4">
              <div class="w-8 h-8 rounded-token-lg bg-white shadow-sm flex items-center justify-center flex-shrink-0 border border-tymeslot-100">
                <Icons.icon name={:list_bullet} class="w-4 h-4 text-tymeslot-400" />
              </div>
              <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mt-2">
                {gettext("Custom answers")}
              </p>
            </div>
            <dl class="space-y-3">
              <div
                :for={field <- displayable_fields}
                class="grid grid-cols-1 md:grid-cols-[1fr_2fr] gap-x-6 gap-y-1"
              >
                <dt class="text-token-sm font-semibold text-tymeslot-500">
                  {field["label"]}
                </dt>
                <dd class="text-token-sm text-tymeslot-700 font-medium">
                  {AnswerRenderer.render(field, @meeting.custom_field_answers[field["id"]])}
                </dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="flex lg:flex-col gap-3 flex-shrink-0 lg:w-[160px]">
          <div :if={@meeting.status != "cancelled" && !Helpers.past_meeting?(@meeting)} class="contents">
            <a
              :if={@meeting.meeting_url}
              href={@meeting.meeting_url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn-primary py-3 px-4 text-token-sm w-full flex items-center justify-center whitespace-nowrap"
            >
              <Icons.icon name={:video} class="w-4 h-4 mr-2 flex-shrink-0" /> Join Meeting
            </a>

            <button
              phx-click="show_reschedule_modal"
              phx-value-id={@meeting.id}
              phx-target={@target}
              disabled={!Helpers.can_reschedule?(@meeting)}
              class={[
                "btn-secondary py-3 px-4 text-token-sm w-full flex items-center justify-center whitespace-nowrap",
                if(!Helpers.can_reschedule?(@meeting), do: "opacity-50 cursor-not-allowed", else: "")
              ]}
            >
              <Icons.icon name={:swap} class="w-4 h-4 mr-2 flex-shrink-0" /> Reschedule
            </button>

            <button
              id={"cancel-meeting-#{@meeting.id}"}
              phx-click="show_cancel_modal"
              phx-value-id={@meeting.id}
              phx-target={@target}
              disabled={@cancelling_meeting == @meeting.id || !Helpers.can_cancel?(@meeting)}
              class={[
                "btn-danger py-3 px-4 text-token-sm w-full flex items-center justify-center whitespace-nowrap",
                if(!Helpers.can_cancel?(@meeting), do: "opacity-50 cursor-not-allowed", else: "")
              ]}
            >
              <span :if={@cancelling_meeting == @meeting.id} class="flex items-center"><CoreComponents.spinner class="h-4 w-4 mr-2" /> Processing...</span>
              <span :if={@cancelling_meeting != @meeting.id} class="flex items-center"><Icons.icon name={:x_mark} class="w-4 h-4 mr-2 flex-shrink-0" /> Cancel</span>
            </button>
          </div>
          <div :if={@meeting.status == "cancelled" or Helpers.past_meeting?(@meeting)} class="hidden lg:block">&nbsp;</div>
        </div>
      </div>
    </div>
    """
  end

  attr :meeting, :map, required: true
  attr :target, :any, required: true

  defp calendar_sync_banner(assigns) do
    ~H"""
    <div class={[
      "flex items-start justify-between gap-4 rounded-2xl px-5 py-4 mb-6 border-2",
      if(@meeting.calendar_sync_status == "externally_deleted",
        do: "bg-red-50 border-red-200 text-red-800",
        else: "bg-amber-50 border-amber-200 text-amber-800"
      )
    ]}>
      <p class="font-medium text-token-sm">
        <span :if={@meeting.calendar_sync_status == "externally_deleted"}>This meeting's event was deleted from your external calendar.</span>
        <span :if={@meeting.calendar_sync_status != "externally_deleted"}>This meeting's event was rescheduled in your external calendar.</span>
      </p>
      <button
        phx-click="dismiss_calendar_sync_banner"
        phx-value-id={@meeting.id}
        phx-target={@target}
        class={[
          "flex-shrink-0 text-token-xs font-black uppercase tracking-wider px-3 py-1.5 rounded-token-lg border transition-colors",
          if(@meeting.calendar_sync_status == "externally_deleted",
            do: "border-red-300 hover:bg-red-100",
            else: "border-amber-300 hover:bg-amber-100"
          )
        ]}
      >
        Dismiss
      </button>
    </div>
    """
  end

  defp status_badges(assigns) do
    ~H"""
    <span :if={@meeting.status == "cancelled"} class="inline-flex items-center gap-1.5 px-3 py-1 bg-red-50 text-red-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-red-100 shadow-sm">
      <Icons.icon name={:x_mark} class="w-3 h-3" /> Cancelled
    </span>
    <span :if={@meeting.status == "reschedule_requested"} class="inline-flex items-center gap-1.5 px-3 py-1 bg-amber-50 text-amber-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-amber-100 shadow-sm">
      <Icons.icon name={:clock} class="w-3 h-3" /> Reschedule Requested
    </span>
    <span :if={@meeting.status not in ["cancelled", "reschedule_requested"] and Helpers.past_meeting?(@meeting)} class="inline-flex items-center gap-1.5 px-3 py-1 bg-tymeslot-100 text-tymeslot-600 text-token-xs font-black uppercase tracking-wider rounded-full border border-tymeslot-200 shadow-sm">
      <Icons.icon name={:check} class="w-3 h-3" /> Completed
    </span>
    <span :if={@meeting.status not in ["cancelled", "reschedule_requested"] and !Helpers.past_meeting?(@meeting)} class="inline-flex items-center gap-1.5 px-3 py-1 bg-emerald-50 text-emerald-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-emerald-100 shadow-sm">
      <Icons.icon name={:calendar} class="w-3 h-3" /> Scheduled
    </span>
    """
  end

  attr :filter, :string, required: true

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div class="card-glass py-20">
      <div class="text-center max-w-sm mx-auto">
        <div class="w-24 h-24 mx-auto mb-8 rounded-token-3xl bg-tymeslot-50 flex items-center justify-center border-2 border-tymeslot-100 shadow-sm transition-transform hover:scale-110 hover:rotate-3 duration-500">
          <Icons.icon name={:calendar} class="w-12 h-12 text-tymeslot-300" />
        </div>
        <h3 class="text-token-2xl font-black text-tymeslot-900 tracking-tight mb-3">
          <%= case @filter do %>
            <% "upcoming" -> %> No upcoming meetings
            <% "past" -> %> No past meetings
            <% "cancelled" -> %> No cancelled meetings
          <% end %>
        </h3>
        <p class="text-tymeslot-500 font-medium text-lg leading-relaxed">
          <%= case @filter do %>
            <% "upcoming" -> %> Your upcoming appointments will appear here automatically.
            <% "past" -> %> You haven't had any meetings in this period yet.
            <% "cancelled" -> %> You don't have any cancelled appointments to show.
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
          <CoreComponents.section_header level={2} icon={:calendar} title="Meeting Management" class="mb-6" />

          <p class="text-tymeslot-500 font-bold text-lg leading-relaxed max-w-2xl mb-8">
            Manage all your scheduled meetings in one place. Filter by status and take quick actions on your appointments.
          </p>

          <div class="flex flex-wrap gap-4">
            <span class="inline-flex items-center gap-2 px-4 py-2 bg-tymeslot-50 text-tymeslot-600 rounded-token-xl text-token-sm font-black border border-tymeslot-100 shadow-sm">
              <div class="w-2 h-2 rounded-full bg-turquoise-500"></div> Real-time updates
            </span>
            <span class="inline-flex items-center gap-2 px-4 py-2 bg-tymeslot-50 text-tymeslot-600 rounded-token-xl text-token-sm font-black border border-tymeslot-100 shadow-sm">
              <div class="w-2 h-2 rounded-full bg-cyan-500"></div> Auto-notifications
            </span>
          </div>
        </div>

        <div class="lg:w-80 space-y-4">
          <.info_card icon={:swap} title="Reschedule" description="Change meeting times" color="turquoise" />
          <.info_card icon={:x_mark} title="Cancel" description="With auto notifications" color="red" />
          <.info_card icon={:video} title="Join Video" description="Quick meeting access" color="blue" />
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
          <Icons.icon name={@icon} class="w-5 h-5" />
        </div>
        <div>
          <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mb-0.5">{@title}</p>
          <p class="text-tymeslot-700 font-bold">{@description}</p>
        </div>
      </div>
    </div>
    """
  end

  # Small coloured pill reflecting a guest's RSVP status.
  attr :status, :string, required: true

  defp guest_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex flex-none items-center gap-1 rounded-full px-2.5 py-0.5 text-token-xs font-bold",
      guest_badge_classes(@status)
    ]}>
      <CoreComponents.icon name={guest_badge_icon(@status)} class="w-3.5 h-3.5" />
      {guest_status_label(@status)}
    </span>
    """
  end

  defp guest_badge_classes("accepted"), do: "bg-green-50 text-green-700 border border-green-100"
  defp guest_badge_classes("declined"), do: "bg-red-50 text-red-600 border border-red-100"
  defp guest_badge_classes(_pending), do: "bg-amber-50 text-amber-700 border border-amber-100"

  defp guest_badge_icon("accepted"), do: "hero-check-circle-mini"
  defp guest_badge_icon("declined"), do: "hero-x-circle-mini"
  defp guest_badge_icon(_pending), do: "hero-clock-mini"

  defp guest_status_label("accepted"), do: gettext("Going")
  defp guest_status_label("declined"), do: gettext("Declined")
  defp guest_status_label(_pending), do: gettext("Pending")

  defp guest_list(%{guests: guests}) when is_list(guests), do: guests
  defp guest_list(_meeting), do: []

  defp guest_initial(%{name: name}) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp guest_initial(%{email: email}) when is_binary(email) and email != "",
    do: email |> String.first() |> String.upcase()

  defp guest_initial(_guest), do: "?"

  defp guest_summary_label(meeting) do
    summary = Meetings.guest_rsvp_summary(guest_list(meeting))
    gettext("%{going} of %{total} going", going: summary.accepted, total: summary.total)
  end
end
