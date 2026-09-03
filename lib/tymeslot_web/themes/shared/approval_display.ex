defmodule TymeslotWeb.Themes.Shared.ApprovalDisplay do
  @moduledoc """
  Whether the booking a confirmation screen is describing is currently held
  for the host's approval.

  Both themes' confirmation components read this from the same source: the
  meeting's own `status`, assigned once a meeting exists (it is what
  `Tymeslot.Bookings.Reschedule` may have re-gated, which the meeting type's
  `requires_approval` flag alone cannot tell), falling back to the meeting
  type's flag when no status has been assigned yet (the embedded-payment
  confirmation path).

  Owner preview and the SaaS demo flow route through
  `Tymeslot.Bookings.DemoOrchestrator`, whose mock meeting exists only to
  render a screen, not to describe a booking that actually happened, so its
  `status` is not a source of truth here. Preview always answers from the
  meeting type instead, so the confirmation screen cannot disagree with the
  approval notice the same preview session already showed on the booking
  form.
  """

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingState

  @doc "Whether the booking this screen describes is currently held for approval."
  @spec awaiting_approval?(map()) :: boolean()
  def awaiting_approval?(%{owner_preview: true} = assigns),
    do: Approval.required?(assigns[:meeting_type])

  def awaiting_approval?(%{meeting_status: status}) when is_binary(status),
    do: MeetingState.awaiting_approval?(%{status: status})

  def awaiting_approval?(assigns), do: Approval.required?(assigns[:meeting_type])
end
