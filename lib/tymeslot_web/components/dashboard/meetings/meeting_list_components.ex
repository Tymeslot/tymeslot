defmodule TymeslotWeb.Components.Dashboard.Meetings.MeetingListComponents do
  @moduledoc """
  UI components for displaying and filtering meetings in the dashboard.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.Seats
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers
  alias TymeslotWeb.Components.Dashboard.Meetings.MeetingListPanels

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
    </div>
    """
  end

  attr :active, :boolean, required: true
  attr :filter, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
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
          do:
            "bg-linear-to-br from-turquoise-600 to-cyan-600 text-white shadow-lg shadow-turquoise-500/20",
          else: "text-tymeslot-500 hover:text-turquoise-600 hover:bg-turquoise-50"
        )
      ]}
    >
      <CoreComponents.icon name={@icon} class={if @active, do: "text-white/90", else: ""} />
      <span>{@label}</span>
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
  attr :target, :any, required: true
  attr :meetings_stream, :any, required: true

  @spec meetings_list(map()) :: Phoenix.LiveView.Rendered.t()
  def meetings_list(assigns) do
    ~H"""
    <div>
      <MeetingListPanels.loading_spinner :if={@loading} />
      <MeetingListPanels.empty_state :if={!@loading and @is_empty} filter={@filter} />
      <div :if={!@loading and !@is_empty} class="space-y-4" id="meetings" phx-update="stream">
        <div :for={{dom_id, meeting} <- @meetings_stream} id={dom_id}>
          <.meeting_card
            meeting={meeting}
            profile={@profile}
            time_format={@time_format}
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
  attr :time_format, :string, required: true
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
              {meeting_title(@meeting)}
            </h4>
            <span
              :if={@meeting.attendee_company}
              class="text-token-sm font-bold text-tymeslot-400 bg-tymeslot-50 px-3 py-1 rounded-token-lg"
            >
              {@meeting.attendee_company}
            </span>
            <.status_badges meeting={@meeting} />
            <span
              :if={group_meeting?(@meeting)}
              class="inline-flex items-center gap-1.5 px-3 py-1 bg-turquoise-50 text-turquoise-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-turquoise-100 shadow-sm"
            >
              <CoreComponents.icon name="hero-users" class="w-3.5 h-3.5" />
              {dgettext("dashboard_bookings", "%{count}/%{capacity} seats taken",
                count: seats_taken(@meeting),
                capacity: @meeting.capacity
              )}
            </span>
            <span
              :if={@meeting.meeting_url}
              class="inline-flex items-center gap-1.5 px-3 py-1 bg-cyan-50 text-cyan-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-cyan-100 shadow-sm"
            >
              <CoreComponents.icon name="hero-video-camera" class="w-3.5 h-3.5" />
              {dgettext("dashboard_bookings", "Video Call")}
            </span>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div class="flex items-center gap-4">
              <div class="w-12 h-12 rounded-token-2xl bg-turquoise-50 flex items-center justify-center shadow-sm border border-turquoise-100 transition-transform group-hover/card:scale-110">
                <CoreComponents.icon name="hero-calendar-days" class="w-6 h-6 text-turquoise-600" />
              </div>
              <div>
                <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mb-0.5">
                  {dgettext("dashboard_bookings", "Date & Time")}
                </p>
                <p class="text-tymeslot-700 font-bold">
                  {Helpers.format_meeting_date(
                    @meeting,
                    Helpers.get_meeting_timezone(@meeting, @profile)
                  )}
                  <span class="text-turquoise-600 ml-1">
                    {Helpers.format_meeting_time(
                      @meeting,
                      Helpers.get_meeting_timezone(@meeting, @profile),
                      @time_format
                    )}
                  </span>
                </p>
              </div>
            </div>

            <%!-- A group slot has no single attendee: every booker is listed
                 in the participants panel below, so the label would otherwise
                 head an empty value. --%>
            <div :if={@meeting.attendee_email} class="flex items-center gap-4">
              <div class="w-12 h-12 rounded-token-2xl bg-blue-50 flex items-center justify-center shadow-sm border border-blue-100 transition-transform group-hover/card:scale-110">
                <CoreComponents.icon name="hero-envelope" class="w-6 h-6 text-blue-600" />
              </div>
              <div>
                <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mb-0.5">
                  {dgettext("dashboard_bookings", "Attendee Email")}
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

          <%!-- Participants panel — group meetings only; the preload already
               filters to live (non-cancelled) participants. --%>
          <div
            :if={participant_list(@meeting) != []}
            class="mt-8 p-5 bg-tymeslot-50/50 rounded-token-2xl border-2 border-tymeslot-50"
          >
            <div class="flex items-center gap-4 mb-4">
              <div class="w-8 h-8 rounded-token-lg bg-white shadow-sm flex items-center justify-center shrink-0 border border-tymeslot-100">
                <CoreComponents.icon name="hero-users" class="w-4 h-4 text-tymeslot-400" />
              </div>
              <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest">
                {dgettext("dashboard_bookings", "Participants")}
              </p>
            </div>
            <ul class="space-y-2.5">
              <li
                :for={participant <- participant_list(@meeting)}
                class="flex items-center justify-between gap-3"
              >
                <span class="flex items-center gap-2.5 min-w-0">
                  <span class="flex h-7 w-7 flex-none items-center justify-center rounded-token-full bg-turquoise-100 text-token-xs font-bold uppercase text-turquoise-700">
                    {person_initial(participant)}
                  </span>
                  <span class="truncate text-token-sm font-medium text-tymeslot-700">
                    {participant.name}
                  </span>
                </span>
                <a
                  href={"mailto:#{participant.email}"}
                  class="truncate text-token-sm font-medium text-tymeslot-500 hover:text-turquoise-600 transition-colors"
                >
                  {participant.email}
                </a>
              </li>
            </ul>
          </div>

          <div
            :if={guest_list(@meeting) != []}
            class="mt-8 p-5 bg-tymeslot-50/50 rounded-token-2xl border-2 border-tymeslot-50"
          >
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-4">
                <div class="w-8 h-8 rounded-token-lg bg-white shadow-sm flex items-center justify-center shrink-0 border border-tymeslot-100">
                  <CoreComponents.icon name="hero-user-group" class="w-4 h-4 text-tymeslot-400" />
                </div>
                <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest">
                  {dgettext("dashboard_bookings", "Guests")}
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
                    {person_initial(guest)}
                  </span>
                  <span class="truncate text-token-sm font-medium text-tymeslot-700">
                    {guest.name || guest.email}
                  </span>
                </span>
                <.guest_status_badge status={guest.status} />
              </li>
            </ul>
          </div>

          <div
            :if={@meeting.attendee_message && @meeting.attendee_message != ""}
            class="mt-8 p-5 bg-tymeslot-50/50 rounded-token-2xl border-2 border-tymeslot-50 flex gap-4 items-start"
          >
            <div class="w-8 h-8 rounded-token-lg bg-white shadow-sm flex items-center justify-center shrink-0 border border-tymeslot-100">
              <CoreComponents.icon name="hero-pencil-square" class="w-4 h-4 text-tymeslot-400" />
            </div>
            <div class="flex-1">
              <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mb-1">
                {dgettext("dashboard_bookings", "Meeting Notes")}
              </p>
              <p class="text-tymeslot-600 font-medium leading-relaxed">{@meeting.attendee_message}</p>
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
              <div class="w-8 h-8 rounded-token-lg bg-white shadow-sm flex items-center justify-center shrink-0 border border-tymeslot-100">
                <CoreComponents.icon name="hero-list-bullet" class="w-4 h-4 text-tymeslot-400" />
              </div>
              <p class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest mt-2">
                {dgettext("dashboard_bookings", "Custom answers")}
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

        <div class="flex lg:flex-col gap-3 shrink-0 lg:w-[160px]">
          <div
            :if={@meeting.status != "cancelled" && !Helpers.past_meeting?(@meeting)}
            class="contents"
          >
            <a
              :if={@meeting.meeting_url}
              href={@meeting.meeting_url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn-primary py-3 px-4 text-token-sm w-full flex items-center justify-center whitespace-nowrap"
            >
              <CoreComponents.icon name="hero-video-camera" class="w-4 h-4 mr-2 shrink-0" />
              {dgettext("dashboard_bookings", "Join Meeting")}
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
              <CoreComponents.icon name="hero-arrows-right-left" class="w-4 h-4 mr-2 shrink-0" />
              {dgettext("dashboard_bookings", "Reschedule")}
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
              <span :if={@cancelling_meeting == @meeting.id} class="flex items-center">
                <CoreComponents.spinner class="h-4 w-4 mr-2" /> {dgettext(
                  "dashboard_bookings",
                  "Processing..."
                )}
              </span>
              <span :if={@cancelling_meeting != @meeting.id} class="flex items-center">
                <CoreComponents.icon name="hero-x-mark" class="w-4 h-4 mr-2 shrink-0" /> {dgettext(
                  "dashboard_bookings",
                  "Cancel"
                )}
              </span>
            </button>
          </div>
          <div
            :if={@meeting.status == "cancelled" or Helpers.past_meeting?(@meeting)}
            class="hidden lg:block"
          >
            &nbsp;
          </div>
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
        <span :if={@meeting.calendar_sync_status == "externally_deleted"}>
          {dgettext(
            "dashboard_bookings",
            "This meeting's event was deleted from your external calendar."
          )}
        </span>
        <span :if={@meeting.calendar_sync_status != "externally_deleted"}>
          {dgettext(
            "dashboard_bookings",
            "This meeting's event was rescheduled in your external calendar."
          )}
        </span>
      </p>
      <button
        phx-click="dismiss_calendar_sync_banner"
        phx-value-id={@meeting.id}
        phx-target={@target}
        class={[
          "shrink-0 text-token-xs font-black uppercase tracking-wider px-3 py-1.5 rounded-token-lg border transition-colors",
          if(@meeting.calendar_sync_status == "externally_deleted",
            do: "border-red-300 hover:bg-red-100",
            else: "border-amber-300 hover:bg-amber-100"
          )
        ]}
      >
        {dgettext("dashboard_bookings", "Dismiss")}
      </button>
    </div>
    """
  end

  defp status_badges(assigns) do
    ~H"""
    <span
      :if={@meeting.status == "cancelled"}
      class="inline-flex items-center gap-1.5 px-3 py-1 bg-red-50 text-red-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-red-100 shadow-sm"
    >
      <CoreComponents.icon name="hero-x-mark" class="w-3 h-3" /> {dgettext(
        "dashboard_bookings",
        "Cancelled"
      )}
    </span>
    <span
      :if={@meeting.status != "cancelled" and MeetingState.awaiting_new_time?(@meeting)}
      class="inline-flex items-center gap-1.5 px-3 py-1 bg-amber-50 text-amber-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-amber-100 shadow-sm"
    >
      <CoreComponents.icon name="hero-clock" class="w-3 h-3" /> {dgettext(
        "dashboard_bookings",
        "Reschedule Requested"
      )}
    </span>
    <span
      :if={
        @meeting.status != "cancelled" and !MeetingState.awaiting_new_time?(@meeting) and
          Helpers.past_meeting?(@meeting)
      }
      class="inline-flex items-center gap-1.5 px-3 py-1 bg-tymeslot-100 text-tymeslot-600 text-token-xs font-black uppercase tracking-wider rounded-full border border-tymeslot-200 shadow-sm"
    >
      <CoreComponents.icon name="hero-check" class="w-3 h-3" /> {dgettext(
        "dashboard_bookings",
        "Completed"
      )}
    </span>
    <span
      :if={
        @meeting.status != "cancelled" and !MeetingState.awaiting_new_time?(@meeting) and
          !Helpers.past_meeting?(@meeting)
      }
      class="inline-flex items-center gap-1.5 px-3 py-1 bg-emerald-50 text-emerald-700 text-token-xs font-black uppercase tracking-wider rounded-full border border-emerald-100 shadow-sm"
    >
      <CoreComponents.icon name="hero-calendar-days" class="w-3 h-3" /> {dgettext(
        "dashboard_bookings",
        "Scheduled"
      )}
    </span>
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

  defp guest_status_label("accepted"), do: dgettext("dashboard_bookings", "Going")
  defp guest_status_label("declined"), do: dgettext("dashboard_bookings", "Declined")
  defp guest_status_label(_pending), do: dgettext("dashboard_bookings", "Pending")

  defp guest_list(%{guests: guests}) when is_list(guests), do: guests
  defp guest_list(_meeting), do: []

  defp group_meeting?(meeting), do: Meetings.group?(meeting)

  # The is_list guard doubles as a NotLoaded guard for callers that render
  # meeting_card without the participants preload.
  defp participant_list(%{participants: participants}) when is_list(participants),
    do: participants

  defp participant_list(_meeting), do: []

  # Seats, not headcount. A booker who brings a guest occupies two of the
  # slot's seats, which is what the public booking page counts down and what
  # the organiser needs to read here — a card saying "1/4" beside a slot
  # advertising "2 seats left" is two answers to the same question.
  defp seats_taken(meeting),
    do: Seats.seats_taken(participant_list(meeting), guest_list(meeting))

  # The title of a group card: the shared slot has no single attendee, so it
  # is named after what was booked rather than left blank. `title` is a
  # required field on every meeting, snapshotted at creation like `capacity`
  # (see `MeetingSchema.group?/1`), so it survives the meeting type being
  # edited or deleted.
  defp meeting_title(%{attendee_name: name}) when is_binary(name) and name != "", do: name
  defp meeting_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp meeting_title(_meeting), do: dgettext("dashboard_bookings", "Group booking")

  defp person_initial(%{name: name}) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp person_initial(%{email: email}) when is_binary(email) and email != "",
    do: email |> String.first() |> String.upcase()

  defp person_initial(_person), do: "?"

  defp guest_summary_label(meeting) do
    summary = Meetings.guest_rsvp_summary(guest_list(meeting))

    dgettext("dashboard_bookings", "%{going} of %{total} going",
      going: summary.accepted,
      total: summary.total
    )
  end
end
