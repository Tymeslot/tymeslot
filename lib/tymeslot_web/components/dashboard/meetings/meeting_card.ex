defmodule TymeslotWeb.Components.Dashboard.Meetings.MeetingCard do
  @moduledoc """
  One booking on the Meetings page: who booked, which meeting type, when, how
  to reach them, their guests, notes and answers, reminders, and the actions
  the booking allows.

  Split out of `MeetingListComponents`, which keeps the list around it.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Seats
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Components.CoreComponents.Containers
  alias TymeslotWeb.Components.CoreComponents.Feedback
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Components.Dashboard.Meetings.GuestStatusPill
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers
  alias TymeslotWeb.Components.Dashboard.Meetings.MeetingActions
  alias TymeslotWeb.Components.Dashboard.Meetings.MeetingStatusBadge
  alias TymeslotWeb.Components.Dashboard.Meetings.RemindersSection

  attr :meeting, :map, required: true
  attr :profile, :any, required: false
  attr :time_format, :string, required: true
  attr :cancelling_meeting, :any, required: false
  attr :sending_reschedule, :any, required: false
  attr :answering_request, :any, default: nil
  attr :target, :any, required: true

  @spec meeting_card(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_card(assigns) do
    timezone = Helpers.get_meeting_timezone(assigns.meeting, assigns[:profile])

    assigns =
      assign(assigns,
        timezone: timezone,
        guests: guest_list(assigns.meeting),
        group?: Helpers.group_meeting?(assigns.meeting),
        participants: Helpers.participants(assigns.meeting),
        answered_fields: answered_fields(assigns.meeting)
      )

    ~H"""
    <Containers.card>
      <.calendar_sync_banner
        :if={
          @meeting.calendar_sync_status in ["externally_deleted", "externally_modified"] and
            is_nil(@meeting.calendar_sync_status_dismissed_at)
        }
        meeting={@meeting}
        target={@target}
      />
      <div class="flex flex-col lg:flex-row lg:items-center justify-between gap-8">
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-3 flex-wrap mb-6">
            <h2 class="text-token-lg font-semibold text-tymeslot-900">
              {meeting_title(@meeting)}
            </h2>
            <span
              :if={@meeting.attendee_company}
              class="text-token-sm font-bold text-tymeslot-400 bg-tymeslot-50 px-3 py-1 rounded-token-lg"
            >
              {@meeting.attendee_company}
            </span>
            <MeetingStatusBadge.status_badges meeting={@meeting} />
            <Feedback.pill
              :if={@group?}
              tone={:brand}
              size={:sm}
              icon="hero-users"
              data-testid="group-seats-badge"
            >
              {seats_label(@meeting, @guests)}
            </Feedback.pill>
            <Feedback.pill
              :if={Meetings.organizer_join_url(@meeting)}
              tone={:info}
              size={:sm}
              icon="hero-video-camera"
            >
              {dgettext("dashboard_bookings", "Video Call")}
            </Feedback.pill>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <Containers.detail_line
              variant={:tile}
              icon="hero-calendar-days"
              label={dgettext("dashboard_bookings", "Date & Time")}
              data-testid="meeting-date-time"
            >
              {Helpers.format_meeting_date(@meeting, @timezone)}
              <span class="block text-turquoise-600">
                {Helpers.format_meeting_time(@meeting, @timezone, @time_format)}
              </span>
            </Containers.detail_line>
            <Containers.detail_line
              :if={@meeting.meeting_type}
              variant={:tile}
              icon="hero-squares-2x2"
              label={dgettext("dashboard_bookings", "Meeting type")}
              data-testid="meeting-type"
            >
              {@meeting.meeting_type}
            </Containers.detail_line>
            <%!-- A group slot has no single attendee: every booker is listed
                 in the participants panel below. --%>
            <Containers.detail_line
              :if={not @group? and @meeting.attendee_email}
              variant={:tile}
              tone={:info}
              icon="hero-envelope"
              label={dgettext("dashboard_bookings", "Attendee Email")}
            >
              <a
                href={"mailto:#{@meeting.attendee_email}"}
                class="hover:text-turquoise-600 transition-colors"
              >
                {@meeting.attendee_email}
              </a>
            </Containers.detail_line>
          </div>

          <%!-- Participants panel, group meetings only. The preload keeps to
               live participants, except on a cancelled meeting, where it also
               brings those who left the slot (released or moved their seat),
               marked as such. --%>
          <.sub_panel
            :if={@participants != []}
            icon="hero-users"
            title={dgettext("dashboard_bookings", "Participants")}
          >
            <ul class="space-y-2.5">
              <li :for={participant <- @participants} class="flex items-center justify-between gap-3">
                <span class="flex items-center gap-2.5 min-w-0">
                  <span class="flex h-7 w-7 flex-none items-center justify-center rounded-token-full bg-turquoise-100 text-token-xs font-bold uppercase text-turquoise-700">
                    {person_initial(participant)}
                  </span>
                  <span class="truncate text-token-sm font-medium text-tymeslot-700">
                    {participant.name}
                  </span>
                  <Feedback.pill
                    :if={participant.cancelled_at}
                    class="flex-none"
                    data-testid="participant-released"
                  >
                    {dgettext("dashboard_bookings", "Left this slot")}
                  </Feedback.pill>
                </span>
                <a
                  href={"mailto:#{participant.email}"}
                  class="truncate text-token-sm font-medium text-tymeslot-500 hover:text-turquoise-600 transition-colors"
                >
                  {participant.email}
                </a>
              </li>
            </ul>
          </.sub_panel>

          <.sub_panel
            :if={@guests != []}
            icon="hero-user-group"
            title={dgettext("dashboard_bookings", "Guests")}
          >
            <:aside>{guest_summary_label(@guests)}</:aside>
            <ul class="space-y-2.5">
              <li :for={guest <- @guests} class="flex items-center justify-between gap-3">
                <span class="flex items-center gap-2.5 min-w-0">
                  <span class="flex h-7 w-7 flex-none items-center justify-center rounded-token-full bg-turquoise-100 text-token-xs font-bold uppercase text-turquoise-700">
                    {person_initial(guest)}
                  </span>
                  <span class="truncate text-token-sm font-medium text-tymeslot-700">
                    {guest.name || guest.email}
                  </span>
                </span>
                <GuestStatusPill.guest_status_pill status={guest.status} />
              </li>
            </ul>
          </.sub_panel>

          <.sub_panel
            :if={@meeting.attendee_message && @meeting.attendee_message != ""}
            icon="hero-pencil-square"
            title={dgettext("dashboard_bookings", "Meeting Notes")}
          >
            <p class="text-tymeslot-600 font-medium leading-relaxed">{@meeting.attendee_message}</p>
          </.sub_panel>

          <.sub_panel
            :if={@answered_fields != []}
            icon="hero-list-bullet"
            title={dgettext("dashboard_bookings", "Custom answers")}
          >
            <dl class="space-y-3">
              <div
                :for={field <- @answered_fields}
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
          </.sub_panel>
          <RemindersSection.reminders_section meeting={@meeting} />
        </div>

        <MeetingActions.action_bar
          meeting={@meeting}
          target={@target}
          answering_request={@answering_request}
          cancelling_meeting={@cancelling_meeting}
        />
      </div>
    </Containers.card>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :rest, :global
  slot :aside, doc: "A short note at the far end of the header, such as a count"
  slot :inner_block, required: true

  @doc """
  A tinted panel inside a card, under a small icon and an uppercase title, for
  a secondary block of the card's content (guests, notes, answers).
  """
  @spec sub_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def sub_panel(assigns) do
    ~H"""
    <section class="mt-8 p-5 bg-tymeslot-50/50 rounded-token-2xl border-2 border-tymeslot-50" {@rest}>
      <div class="flex items-center justify-between gap-4 mb-4">
        <div class="flex items-center gap-4">
          <div class="w-8 h-8 rounded-token-lg bg-white shadow-sm flex items-center justify-center shrink-0 border border-tymeslot-100">
            <Icons.icon name={@icon} class="w-4 h-4 text-tymeslot-400" />
          </div>
          <h3 class="text-token-base font-semibold text-tymeslot-900">
            {@title}
          </h3>
        </div>
        <span :if={@aside != []} class="text-token-sm font-bold text-tymeslot-500">
          {render_slot(@aside)}
        </span>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :meeting, :map, required: true
  attr :target, :any, required: true

  defp calendar_sync_banner(assigns) do
    ~H"""
    <div class={[
      "flex items-start justify-between gap-4 rounded-token-2xl px-5 py-4 mb-6 border-2",
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
      <Buttons.action_button
        variant={:outline}
        size={:sm}
        phx-click="dismiss_calendar_sync_banner"
        phx-value-id={@meeting.id}
        phx-target={@target}
        class="shrink-0"
      >
        {dgettext("dashboard_bookings", "Dismiss")}
      </Buttons.action_button>
    </div>
    """
  end

  # The custom-field questions this booking actually answered.
  defp answered_fields(meeting) do
    Enum.filter(meeting.custom_fields_snapshot, fn field ->
      AnswerRenderer.render(field, meeting.custom_field_answers[field["id"]]) != ""
    end)
  end

  defp guest_list(%{guests: guests}) when is_list(guests), do: guests
  defp guest_list(_meeting), do: []

  # A cancelled group meeting holds no seats any more, so "0/3" would only
  # say that it is cancelled. What the host wants to know is who was still
  # booked when it was called off: the participants whose own seat was never
  # released (the host cancelled the slot, or its calendar event was deleted).
  # A slot cancelled because its last seat was released had nobody left.
  defp seats_label(%{status: "cancelled"} = meeting, _guests) do
    case Enum.count(Helpers.participants(meeting), &is_nil(&1.cancelled_at)) do
      0 ->
        dgettext("dashboard_bookings", "Every spot was released")

      booked ->
        dngettext(
          "dashboard_bookings",
          "%{count} person was booked",
          "%{count} people were booked",
          booked
        )
    end
  end

  # Seats, not headcount. A booker who brings a guest occupies two of the
  # slot's seats, which is what the public booking page counts down and what
  # the organiser needs to read here: a card saying "1/4" beside a slot
  # advertising "2 seats left" is two answers to the same question.
  defp seats_label(meeting, guests) do
    dgettext("dashboard_bookings", "%{count}/%{capacity} seats taken",
      count: Seats.seats_taken(Helpers.participants(meeting), guests),
      capacity: meeting.capacity
    )
  end

  # A solo card is titled after its attendee. A group card has no single
  # attendee, so it is named after what was booked: `title` is a required
  # field on every meeting, snapshotted at creation, so it survives the
  # meeting type being edited or deleted.
  defp meeting_title(meeting) do
    if Helpers.group_meeting?(meeting),
      do: group_title(meeting),
      else: solo_title(meeting)
  end

  defp solo_title(%{attendee_name: name}) when is_binary(name) and name != "", do: name
  defp solo_title(meeting), do: group_title(meeting)

  defp group_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp group_title(_meeting), do: dgettext("dashboard_bookings", "Group booking")

  defp person_initial(%{name: name}) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp person_initial(%{email: email}) when is_binary(email) and email != "",
    do: email |> String.first() |> String.upcase()

  defp person_initial(_person), do: "?"

  defp guest_summary_label(guests) do
    summary = Meetings.guest_rsvp_summary(guests)

    dgettext("dashboard_bookings", "%{going} of %{total} going",
      going: summary.accepted,
      total: summary.total
    )
  end
end
