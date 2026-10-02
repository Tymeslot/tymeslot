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

  alias Tymeslot.Meetings.MeetingState
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers

  attr :meeting, :map, required: true
  attr :target, :any, required: true
  attr :answering_request, :any, required: true
  attr :cancelling_meeting, :any, required: true

  @doc "The action column for one booking card."
  @spec action_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def action_bar(assigns) do
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
        <CoreComponents.loading_button
          id={"approve-request-#{@meeting.id}"}
          phx-click="approve_request"
          phx-value-id={@meeting.id}
          phx-target={@target}
          loading={@answering_request == @meeting.id}
          loading_text={dgettext("dashboard_bookings", "Approve")}
          data-testid="approve-request"
          size={:sm}
          icon="hero-check"
          class="w-full"
        >
          {dgettext("dashboard_bookings", "Approve")}
        </CoreComponents.loading_button>

        <CoreComponents.action_button
          phx-click="show_decline_modal"
          phx-value-id={@meeting.id}
          phx-target={@target}
          disabled={@answering_request == @meeting.id}
          data-testid="decline-request"
          variant={:danger_soft}
          size={:sm}
          icon="hero-x-mark"
          class="w-full"
        >
          {dgettext("dashboard_bookings", "Decline")}
        </CoreComponents.action_button>
      </div>

      <div
        :if={
          @meeting.status != "cancelled" && !MeetingState.awaiting_approval?(@meeting) &&
            !Helpers.past_meeting?(@meeting)
        }
        class="contents"
      >
        <CoreComponents.action_link
          :if={@meeting.meeting_url}
          href={@meeting.meeting_url}
          target="_blank"
          rel="noopener noreferrer"
          size={:sm}
          icon="hero-video-camera"
          class="w-full"
        >
          {dgettext("dashboard_bookings", "Join meeting")}
        </CoreComponents.action_link>

        <CoreComponents.action_button
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
        </CoreComponents.action_button>

        <CoreComponents.action_button
          phx-click="show_reschedule_modal"
          phx-value-id={@meeting.id}
          phx-target={@target}
          disabled={!Helpers.can_reschedule?(@meeting)}
          variant={:secondary}
          size={:sm}
          icon="hero-arrows-right-left"
          class="w-full"
        >
          {dgettext("dashboard_bookings", "Reschedule")}
        </CoreComponents.action_button>

        <CoreComponents.loading_button
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
        </CoreComponents.loading_button>
      </div>
      <div
        :if={
          (@meeting.status == "cancelled" or Helpers.past_meeting?(@meeting)) and
            not MeetingState.awaiting_approval?(@meeting)
        }
        class="hidden lg:block"
      >
        &nbsp;
      </div>
    </div>
    """
  end
end
