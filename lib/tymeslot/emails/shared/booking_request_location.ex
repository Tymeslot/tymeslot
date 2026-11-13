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
  alias Tymeslot.MeetingTypes

  @doc """
  The place a meeting is held at, as written, for one held somewhere named:
  an in-person or custom location with its text. Such a meeting can also
  have a video room (Quick Add offers both), and the place is then still the
  location, the room being linked on its own. nil for any other meeting.
  """
  @spec place(Meeting.t()) :: String.t() | nil
  def place(%{location_kind: kind, location: location})
      when kind in [:in_person, :custom] and is_binary(location) and location != "",
      do: location

  def place(_meeting), do: nil

  @doc "The location kind, used to pick the label `Formatting.format_location/1` shows."
  @spec type(Meeting.t()) :: :video | :phone | :in_person | :in_person_to_arrange | :custom
  # A booking made against a meeting type's location list already recorded
  # which kind it chose, so there is nothing to infer. This clause comes
  # first precisely because it is the only one that cannot be wrong.
  def type(%Meeting{location_kind: :video}), do: :video
  def type(%Meeting{location_kind: :phone}), do: :phone
  # An in-person booking made on a location offering no venue is one whose
  # address the host arranges after booking, which the emails say in so many
  # words. A nil `venue_id` alone does not mean that: it is also what a venue
  # deleted after booking leaves.
  def type(%Meeting{location_kind: :in_person, address_to_arrange: true}),
    do: :in_person_to_arrange

  def type(%Meeting{location_kind: :in_person}), do: :in_person
  def type(%Meeting{location_kind: :custom}), do: :custom

  def type(%Meeting{meeting_url: url}) when is_binary(url), do: :video

  # A held request has no room yet — `Approval.approve/1` only schedules one,
  # through `Activation.activate_in_transaction(confirmed, with_video_room: true)`,
  # once the host says yes — but `video_integration_id` is already set at booking time and
  # is the same signal `Bookings.Activation.wants_video_room?/2` uses to know
  # a meeting is heading for a video room. Reading it here means a held video
  # request shows "Video Call" instead of "TBD" while the room is still
  # pending.
  def type(%Meeting{video_integration_id: id}) when is_integer(id), do: :video
  # Meetings booked before `location_kind` existed. Their location strings
  # were written by this application, never by a host, so matching the
  # literals it used is sound for exactly those rows and nothing else.
  def type(%Meeting{location: location}) do
    case legacy_placeholder(location) do
      kind when kind in [:phone, :in_person] -> kind
      _other -> :custom
    end
  end

  def type(_meeting), do: :custom

  @doc """
  `location`, of the kind `type/1` classed it as, as the reader sees it in
  the current locale: a default location label ("In person") in their
  language, a venue or the host's own text as written
  (`Tymeslot.MeetingTypes.display_location/2`).
  """
  @spec display(String.t() | nil, atom() | nil) :: String.t() | nil
  def display(location, :in_person_to_arrange),
    do: MeetingTypes.display_location(location, :in_person)

  def display(location, type) when type in [:in_person, :custom, :phone, :video],
    do: MeetingTypes.display_location(location, type)

  def display(location, _type), do: location

  @doc """
  What a location string stood for when an older release wrote an English
  placeholder in place of a place: `:to_be_determined` for "To be
  determined", or the kind a bare "In Person" or "Phone Call" named. nil for
  any other string, a real place included.

  Only meetings booked before `location_kind` existed carry these, so a
  caller reads it for a meeting whose `location_kind` is nil; a host can
  write the same words as a custom location since.
  """
  @spec legacy_placeholder(String.t() | nil) :: :to_be_determined | :in_person | :phone | nil
  def legacy_placeholder("To be determined"), do: :to_be_determined
  def legacy_placeholder("In Person"), do: :in_person
  def legacy_placeholder("Phone Call"), do: :phone
  def legacy_placeholder(_location), do: nil
end
