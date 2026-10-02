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
  alias TymeslotWeb.Components.CoreComponents
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
        answered_fields: answered_fields(assigns.meeting)
      )

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
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-3 flex-wrap mb-6">
            <h4 class="text-token-2xl font-black text-tymeslot-900 tracking-tight group-hover/card:text-turquoise-700 transition-colors">
              {@meeting.attendee_name}
            </h4>
            <span
              :if={@meeting.attendee_company}
              class="text-token-sm font-bold text-tymeslot-400 bg-tymeslot-50 px-3 py-1 rounded-token-lg"
            >
              {@meeting.attendee_company}
            </span>
            <MeetingStatusBadge.status_badges meeting={@meeting} />
            <CoreComponents.pill
              :if={@meeting.meeting_url}
              tone={:info}
              size={:sm}
              icon="hero-video-camera"
            >
              {dgettext("dashboard_bookings", "Video Call")}
            </CoreComponents.pill>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <CoreComponents.detail_line
              variant={:tile}
              icon="hero-calendar-days"
              label={dgettext("dashboard_bookings", "Date & Time")}
            >
              {Helpers.format_meeting_date(@meeting, @timezone)}
              <span class="block text-turquoise-600">
                {Helpers.format_meeting_time(@meeting, @timezone, @time_format)}
              </span>
            </CoreComponents.detail_line>
            <CoreComponents.detail_line
              :if={@meeting.meeting_type}
              variant={:tile}
              icon="hero-squares-2x2"
              label={dgettext("dashboard_bookings", "Meeting type")}
              data-testid="meeting-type"
            >
              {@meeting.meeting_type}
            </CoreComponents.detail_line>
            <CoreComponents.detail_line
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
            </CoreComponents.detail_line>
          </div>

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
                    {guest_initial(guest)}
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
    </div>
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
            <CoreComponents.icon name={@icon} class="w-4 h-4 text-tymeslot-400" />
          </div>
          <h5 class="text-token-xs font-black text-tymeslot-400 uppercase tracking-widest">
            {@title}
          </h5>
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
      <CoreComponents.action_button
        variant={:outline}
        size={:sm}
        phx-click="dismiss_calendar_sync_banner"
        phx-value-id={@meeting.id}
        phx-target={@target}
        class="shrink-0"
      >
        {dgettext("dashboard_bookings", "Dismiss")}
      </CoreComponents.action_button>
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

  defp guest_initial(%{name: name}) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp guest_initial(%{email: email}) when is_binary(email) and email != "",
    do: email |> String.first() |> String.upcase()

  defp guest_initial(_guest), do: "?"

  defp guest_summary_label(guests) do
    summary = Meetings.guest_rsvp_summary(guests)

    dgettext("dashboard_bookings", "%{going} of %{total} going",
      going: summary.accepted,
      total: summary.total
    )
  end
end
