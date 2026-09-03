defmodule Tymeslot.Emails.Shared.BookingRequestLocation do
  @moduledoc """
  Classifies a meeting's location for display.

  Originally written for the three booking-approval templates
  (`BookingApprovalRequest`, `BookingRequestOutcome`, `BookingRequestReceived`),
  which render straight from `Meeting.t()` rather than a pre-built
  appointment-details payload. `AppointmentBuilder.from_meeting/2` and
  `Templates.RescheduleRequest` delegate to this instead of keeping their own
  copies, so this is now the one definition of "what kind of location is
  this" across the email tree.
  """

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  @doc "The location kind, used to pick the label `Formatting.format_location/1` shows."
  @spec type(Meeting.t()) :: :video | :phone | :in_person | :custom
  def type(%Meeting{meeting_url: url}) when is_binary(url), do: :video

  # A held request has no room yet — `Approval.approve/1` only creates one via
  # `Activation.activate(confirmed, with_video_room: true)` once the host
  # says yes — but `video_integration_id` is already set at booking time and
  # is the same signal `Bookings.Activation.wants_video_room?/2` uses to know
  # a meeting is heading for a video room. Reading it here means a held video
  # request shows "Video Call" instead of "TBD" while the room is still
  # pending.
  def type(%Meeting{video_integration_id: id}) when is_integer(id), do: :video
  def type(%Meeting{location: "Phone Call"}), do: :phone
  def type(%Meeting{location: "In Person"}), do: :in_person
  def type(_meeting), do: :custom
end
