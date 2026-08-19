defmodule TymeslotWeb.MeetingRequestLive.View do
  @moduledoc """
  Markup for the page a host answers a booking request on.

  Split from the LiveView so the state machine and the markup can each be read
  without scrolling past the other. Five states: the request is open, or it
  has already been approved, declined, expired, or the link is not one we can
  read.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Validation.Constraints

  # The host is answering about the invitee's time, so both timestamps render
  # in the invitee's zone rather than silently in UTC.
  @displayed_at "%a %d %b %Y, %H:%M"

  attr :state, :atom, required: true
  attr :meeting, :map, default: nil
  attr :choosing, :atom, default: :approve
  attr :decline_reason, :string, default: ""

  @spec page(map()) :: Phoenix.LiveView.Rendered.t()
  def page(assigns) do
    ~H"""
    <div class="min-h-screen bg-tymeslot-50 px-4 py-12">
      <div class="mx-auto w-full max-w-2xl">
        <.glass_morphism_card>
          <div class="p-6 sm:p-8">
            <.outcome :if={@state != :awaiting} state={@state} meeting={@meeting} />
            <.open_request
              :if={@state == :awaiting}
              meeting={@meeting}
              choosing={@choosing}
              decline_reason={@decline_reason}
            />
          </div>
        </.glass_morphism_card>
      </div>
    </div>
    """
  end

  attr :meeting, :map, required: true
  attr :choosing, :atom, required: true
  attr :decline_reason, :string, required: true

  defp open_request(assigns) do
    ~H"""
    <div>
      <.section_header title={dgettext("booking", "Booking request")} icon="hero-inbox-arrow-down" />

      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("booking", "%{name} would like to book time with you.",
          name: @meeting.attendee_name
        )}
      </p>

      <div class="mt-6 space-y-3">
        <.detail_row label={dgettext("booking", "When")} value={when_line(@meeting)} />
        <.detail_row label={dgettext("booking", "Duration")} value={duration_line(@meeting)} />
        <.detail_row
          label={dgettext("booking", "Type")}
          value={@meeting.meeting_type || dgettext("booking", "Meeting")}
        />
        <.detail_row label={dgettext("booking", "From")} value={from_line(@meeting)} />
        <.detail_row
          :if={@meeting.attendee_message not in [nil, ""]}
          label={dgettext("booking", "Message")}
          value={@meeting.attendee_message}
        />
      </div>

      <.info_box :if={@meeting.approval_deadline_at} variant={:warning} class="mt-6">
        {dgettext(
          "booking",
          "If you don't answer by %{deadline}, this request lapses and the slot is released.",
          deadline: deadline_line(@meeting)
        )}
      </.info_box>

      <div class="mt-8 flex flex-wrap gap-3">
        <.action_button
          variant={:primary}
          phx-click="approve"
          data-testid="approve-request"
        >
          {dgettext("booking", "Approve booking")}
        </.action_button>

        <.action_button
          :if={@choosing != :decline}
          variant={:outline}
          phx-click="choose"
          phx-value-intent="decline"
        >
          {dgettext("booking", "Decline")}
        </.action_button>
      </div>

      <div :if={@choosing == :decline} class="mt-6 border-t border-tymeslot-200 pt-6">
        <form id="decline-request-form" phx-change="update_reason" phx-submit="decline">
          <.input
            type="textarea"
            name="reason"
            value={@decline_reason}
            label={dgettext("booking", "Reason (optional)")}
            placeholder={dgettext("booking", "Shared with %{name}.", name: @meeting.attendee_name)}
            maxlength={Constraints.decline_reason_max_length()}
          />

          <div class="mt-4 flex flex-wrap gap-3">
            <.action_button variant={:danger} phx-click="decline" data-testid="decline-request">
              {dgettext("booking", "Decline booking")}
            </.action_button>

            <.action_button
              variant={:secondary}
              type="button"
              phx-click="choose"
              phx-value-intent="approve"
            >
              {dgettext("booking", "Back")}
            </.action_button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :state, :atom, required: true
  attr :meeting, :map, default: nil

  defp outcome(assigns) do
    ~H"""
    <div class="text-center">
      <.icon_badge>
        <.icon name={outcome_icon(@state)} class="w-7 h-7 text-white" />
      </.icon_badge>

      <h1 class="display-md mt-6">{outcome_title(@state)}</h1>

      <p class="mt-3 text-token-base text-tymeslot-600">
        {outcome_body(@state, @meeting)}
      </p>
    </div>
    """
  end

  defp outcome_icon(:approved), do: "hero-check-circle"
  defp outcome_icon(:declined), do: "hero-x-circle"
  defp outcome_icon(:expired), do: "hero-clock"
  defp outcome_icon(:too_late), do: "hero-clock"
  defp outcome_icon(_state), do: "hero-question-mark-circle"

  defp outcome_title(:approved), do: dgettext("booking", "Booking confirmed")
  defp outcome_title(:declined), do: dgettext("booking", "Booking declined")
  defp outcome_title(:expired), do: dgettext("booking", "Request expired")
  defp outcome_title(:too_late), do: dgettext("booking", "Too late to answer")
  defp outcome_title(_state), do: dgettext("booking", "Link not recognised")

  defp outcome_body(:approved, meeting) do
    dgettext("booking", "%{name} has been sent the confirmation and the calendar invite.",
      name: attendee_name(meeting)
    )
  end

  defp outcome_body(:declined, meeting) do
    dgettext("booking", "The slot is free again and %{name} has been told.",
      name: attendee_name(meeting)
    )
  end

  defp outcome_body(:expired, meeting) do
    dgettext("booking", "Nobody answered in time, so the slot was released and %{name} was told.",
      name: attendee_name(meeting)
    )
  end

  defp outcome_body(:too_late, _meeting) do
    dgettext("booking", "This meeting's start time has passed, so it can no longer be confirmed.")
  end

  defp outcome_body(_state, _meeting) do
    dgettext(
      "booking",
      "This link is no longer valid. It may have expired, or the request may have been removed."
    )
  end

  defp attendee_name(nil), do: dgettext("booking", "the person who booked")
  defp attendee_name(%{attendee_name: nil}), do: dgettext("booking", "the person who booked")
  defp attendee_name(%{attendee_name: name}), do: name

  defp when_line(meeting), do: displayed(meeting.start_time, timezone(meeting))

  defp deadline_line(meeting), do: displayed(meeting.approval_deadline_at, timezone(meeting))

  defp displayed(nil, _timezone), do: dgettext("booking", "Not set")

  defp displayed(datetime, timezone) do
    local = DateTimeUtils.convert_to_timezone(datetime, timezone)
    "#{Calendar.strftime(local, @displayed_at)} (#{timezone})"
  end

  defp timezone(%{attendee_timezone: nil}), do: "Etc/UTC"
  defp timezone(%{attendee_timezone: timezone}), do: timezone

  defp duration_line(%{duration: nil}), do: dgettext("booking", "Not set")

  defp duration_line(%{duration: minutes}),
    do: dgettext("booking", "%{count} minutes", count: minutes)

  defp from_line(meeting), do: "#{meeting.attendee_name} (#{meeting.attendee_email})"
end
