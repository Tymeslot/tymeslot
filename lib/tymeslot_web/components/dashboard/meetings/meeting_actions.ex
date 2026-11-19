defmodule TymeslotWeb.Components.Dashboard.Meetings.MeetingActions do
  @moduledoc """
  The column of actions on a booking card.

  Split out of `MeetingListComponents` so each module stays within the
  project's size limit, and because what a host may do with a booking is a
  subject of its own: a held request offers only approve and decline, a live
  booking offers join, guests, reschedule and cancel, and a past or cancelled
  one offers nothing at all.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingState
  alias TymeslotWeb.Components.Dashboard.Appointments.JoinLink
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers

  attr :meeting, :map, required: true
  attr :series?, :boolean, default: false, doc: "a session of a one-to-one series"

  attr :request_count, :integer,
    default: nil,
    doc: "how many sessions the open series request it belongs to holds"

  attr :target, :any, required: true

  attr :answering_request, :any,
    required: true,
    doc: "the ids of the requests whose answer is in flight (a `MapSet`)"

  attr :cancelling_meeting, :any, required: true

  @doc "The action column for one booking card."
  @spec action_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def action_bar(assigns) do
    assigns = assign(assigns, :join_url, Meetings.organizer_join_url(assigns.meeting))

    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:flex lg:flex-col gap-3 shrink-0 lg:w-[160px]">
      <%!-- A held request offers exactly two actions. Join, Reschedule and
              Cancel all presuppose a meeting that is happening, and offering
              them here is what let a host "reschedule" a booking they had
              never agreed to. --%>
      <%!-- Decline and Cancel use the soft destructive style: they sit beside
              the action the card is for and must not outweigh it. The solid red
              button is the confirm inside the modal each one opens. --%>
      <div :if={MeetingState.awaiting_approval?(@meeting)} class="contents">
        <.loading_button
          id={"approve-request-#{@meeting.id}"}
          phx-click="approve_request"
          phx-value-id={@meeting.id}
          phx-target={@target}
          loading={MapSet.member?(@answering_request, @meeting.id)}
          loading_text={dgettext("dashboard_bookings", "Approve")}
          data-testid="approve-request"
          size={:sm}
          icon="hero-check"
          class="w-full"
        >
          {approve_label(@request_count)}
        </.loading_button>

        <.action_button
          phx-click="show_decline_modal"
          phx-value-id={@meeting.id}
          phx-target={@target}
          disabled={MapSet.member?(@answering_request, @meeting.id)}
          data-testid="decline-request"
          variant={:danger_soft}
          size={:sm}
          icon="hero-x-mark"
          class="w-full"
        >
          {decline_label(@request_count)}
        </.action_button>
      </div>

      <.action_button
        :if={@series?}
        id={"view-series-#{@meeting.id}"}
        phx-click="series:show"
        phx-value-series={@meeting.series_id}
        phx-target={@target}
        data-testid="view-series"
        variant={:outline}
        size={:sm}
        icon="hero-queue-list"
        class="w-full"
      >
        {dgettext("dashboard_booking_series", "View series")}
      </.action_button>

      <div
        :if={
          @meeting.status != :cancelled && !MeetingState.awaiting_approval?(@meeting) &&
            !Helpers.past_meeting?(@meeting)
        }
        class="contents"
      >
        <%!-- Wraps rather than overflowing the 160px desktop column: most
              translations of "Join meeting" are wider than it. --%>
        <%!-- A pending reschedule request has voided the slot and the
              attendee has been told it is off, so there is no call to join.
              The room itself stays on the row: the rebooked meeting may reuse
              it. --%>
        <JoinLink.join_link
          :if={@join_url && !MeetingState.awaiting_new_time?(@meeting)}
          url={@join_url}
          size={:sm}
          class="w-full whitespace-normal text-center"
        />

        <.action_button
          :if={Helpers.can_add_guests?(@meeting)}
          id={"add-guests-#{@meeting.id}"}
          phx-click="show_add_guests_modal"
          phx-value-id={@meeting.id}
          phx-target={@target}
          data-testid="add-guests"
          variant={:success}
          size={:sm}
          icon="hero-user-plus"
          class="w-full"
        >
          {dgettext("dashboard_bookings", "Add guest")}
        </.action_button>

        <.action_button
          id={"reschedule-meeting-#{@meeting.id}"}
          phx-click="show_reschedule_modal"
          phx-value-id={@meeting.id}
          phx-target={@target}
          disabled={!Helpers.can_reschedule?(@meeting)}
          tooltip={reschedule_refusal_tip(@meeting)}
          variant={:secondary}
          size={:sm}
          icon="hero-arrows-right-left"
          class="w-full"
        >
          {dgettext("dashboard_bookings", "Reschedule")}
        </.action_button>

        <.loading_button
          id={"cancel-meeting-#{@meeting.id}"}
          phx-click="show_cancel_modal"
          phx-value-id={@meeting.id}
          phx-target={@target}
          loading={@cancelling_meeting == @meeting.id}
          loading_text={dgettext("dashboard_bookings", "Processing...")}
          disabled={!Helpers.can_cancel?(@meeting)}
          variant={:danger_soft}
          size={:sm}
          icon="hero-x-mark"
          class="w-full"
        >
          {dgettext("dashboard_bookings", "Cancel")}
        </.loading_button>
      </div>
      <div
        :if={
          (@meeting.status == :cancelled or Helpers.past_meeting?(@meeting)) and
            not MeetingState.awaiting_approval?(@meeting)
        }
        class="hidden lg:block"
      >
        &nbsp;
      </div>
    </div>
    """
  end

  # Why the Reschedule button is disabled, where the reason is one the host
  # cannot tell from the card alone; `false` leaves it without a tooltip.
  defp reschedule_refusal_tip(meeting) do
    case Policy.can_host_change_time?(meeting) do
      {:error, {:not_reschedulable, :planned}} ->
        dgettext("dashboard_bookings", "Move a fixed date from its meeting type.")

      {:error, {:not_reschedulable, :already_requested}} ->
        awaiting_new_time_tip(meeting)

      _reschedulable_or_self_explanatory ->
        false
    end
  end

  defp awaiting_new_time_tip(meeting) do
    if Helpers.group_meeting?(meeting),
      do: dgettext("dashboard_bookings", "Waiting for the participants to pick a new time"),
      else:
        dgettext("dashboard_bookings", "Waiting for %{name} to pick a new time",
          name: meeting.attendee_name
        )
  end

  # A session of a series request is answered with the whole request.
  defp approve_label(nil), do: dgettext("dashboard_bookings", "Approve")

  defp approve_label(count),
    do:
      dngettext("dashboard_booking_series", "Approve all %{count}", "Approve all %{count}", count)

  defp decline_label(nil), do: dgettext("dashboard_bookings", "Decline")

  defp decline_label(count),
    do:
      dngettext("dashboard_booking_series", "Decline all %{count}", "Decline all %{count}", count)
end
