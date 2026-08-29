defmodule Tymeslot.Emails.Shared.BookingRequestLocation do
  @moduledoc """
  Classifies a meeting's location for display.

  Shared by the three booking-approval templates (`BookingApprovalRequest`,
  `BookingRequestOutcome`, `BookingRequestReceived`), which render straight
  from `Meeting.t()` rather than a pre-built appointment-details payload, so
  they cannot reach `AppointmentBuilder`'s private equivalent.
  """

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  @doc "The location kind, used to pick the label `Formatting.format_location/1` shows."
  @spec type(Meeting.t()) :: :video | :phone | :in_person | :custom
  def type(%Meeting{meeting_url: url}) when is_binary(url), do: :video
  def type(%Meeting{location: "Phone Call"}), do: :phone
  def type(%Meeting{location: "In Person"}), do: :in_person
  def type(_meeting), do: :custom
end
