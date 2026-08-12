defmodule Tymeslot.Meetings.Recipient do
  @moduledoc """
  A normalised "person on this meeting" for notification purposes.

  Solo meetings carry their attendee on the meeting row (`attendee_*`
  columns); group meetings carry one live `meeting_participants` row per
  booker. This struct unifies the two shapes so notification code (emails,
  ICS attachments, reminders) can iterate people without caring which shape
  the meeting has.

  `as_seen_by/2` and `meeting_view/2` are the inverse direction: they project
  a recipient back onto the meeting's `attendee_*` fields, so the existing
  email templates and the ICS generator all render the right person without
  any template changes. For participant recipients the cancel and reschedule
  URLs are replaced with the participant's tokenised seat URLs. The two
  differ only in return shape: `as_seen_by/2` returns a `%MeetingSchema{}`
  for the few callers that need one, `meeting_view/2` a plain map for
  everyone else.
  """

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema

  @enforce_keys [:kind, :email]
  defstruct [
    :kind,
    :name,
    :email,
    :phone,
    :company,
    :message,
    :timezone,
    :locale,
    :custom_field_answers,
    :participant_id,
    :management_token
  ]

  @type t :: %__MODULE__{
          kind: :attendee | :participant,
          name: String.t() | nil,
          email: String.t(),
          phone: String.t() | nil,
          company: String.t() | nil,
          message: String.t() | nil,
          timezone: String.t() | nil,
          locale: String.t(),
          custom_field_answers: map(),
          participant_id: binary() | nil,
          management_token: String.t() | nil
        }

  @doc """
  Everyone on the meeting who should receive attendee-facing notifications.

  Solo meetings return a single recipient built from the `attendee_*` fields;
  group meetings return one recipient per live participant. The two are
  unioned rather than chosen between, because a meeting type switched from
  solo to group can leave a meeting carrying both. A group meeting whose
  participants have all cancelled returns `[]` (its `attendee_*` fields are
  empty by contract).

  A meeting converted from solo to group carries the same person twice: once
  as the attendee-column recipient from before the conversion, once as the
  participant row `GroupConversion` built from those same columns. Those are
  deduplicated on downcased email, with the participant entry winning — it
  carries the seat identity and tokenised cancel/reschedule URLs the attendee
  entry lacks — so callers never double-notify the converted booker.
  """
  @spec for_meeting(MeetingSchema.t()) :: [t()]
  def for_meeting(%MeetingSchema{} = meeting) do
    participants =
      meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Enum.map(&from_participant/1)

    participant_emails = MapSet.new(participants, &String.downcase(&1.email))

    # Union, not either/or. A meeting normally carries one shape or the
    # other, but a meeting type switched from solo to group leaves rows that
    # carry both: an attendee on the meeting row from before the switch, and
    # participants who joined after it. Dropping the attendee there would
    # quietly stop notifying someone who still holds the booking — unless a
    # participant already covers that same email, in which case keeping both
    # would double-notify them instead.
    attendees =
      meeting
      |> attendee_recipients()
      |> Enum.reject(&MapSet.member?(participant_emails, String.downcase(&1.email)))

    attendees ++ participants
  end

  @doc """
  The meeting as the given participant sees it: their own details in the
  `attendee_*` fields, and their tokenised seat URLs.

  Shorthand for `as_seen_by/2` composed with `from_participant/1`, for callers
  that hold a participant row rather than a recipient.
  """
  @spec meeting_as_seen_by(MeetingSchema.t(), ParticipantSchema.t()) :: MeetingSchema.t()
  def meeting_as_seen_by(%MeetingSchema{} = meeting, %ParticipantSchema{} = participant),
    do: as_seen_by(meeting, from_participant(participant))

  @doc "Builds a recipient from a participant row (live or cancelled)."
  @spec from_participant(ParticipantSchema.t()) :: t()
  def from_participant(%ParticipantSchema{} = participant) do
    %__MODULE__{
      kind: :participant,
      name: participant.name,
      email: participant.email,
      phone: participant.phone,
      company: participant.company,
      message: participant.message,
      timezone: participant.timezone,
      locale: participant.locale || "en",
      custom_field_answers: participant.custom_field_answers || %{},
      participant_id: participant.id,
      management_token: participant.management_token
    }
  end

  @doc """
  The meeting as the given recipient sees it.

  `:attendee` recipients see the meeting unchanged. `:participant`
  recipients see their own data in the `attendee_*` fields and their
  tokenised seat URLs in `cancel_url`/`reschedule_url`.

  Returns a `%MeetingSchema{}`, for the handful of callers that must have one
  (the webhook/Telegram/Slack dispatchers pattern-match on the struct, and
  `RescheduleRequest.render/1` does too). Everyone else should use
  `meeting_view/2`, which does the same overlay onto a plain map.
  """
  @spec as_seen_by(MeetingSchema.t(), t()) :: MeetingSchema.t()
  def as_seen_by(%MeetingSchema{} = meeting, %__MODULE__{kind: :attendee}), do: meeting

  def as_seen_by(%MeetingSchema{} = meeting, %__MODULE__{kind: :participant} = recipient),
    do: struct!(meeting, overlay(recipient))

  @doc """
  The meeting as the given recipient sees it, as a plain map.

  Same overlay as `as_seen_by/2`, but returns a doctored map rather than a
  `%MeetingSchema{}`, so nothing downstream can mistake the overlay for a
  persisted row.
  """
  @spec meeting_view(MeetingSchema.t(), t()) :: map()
  def meeting_view(%MeetingSchema{} = meeting, %__MODULE__{kind: :attendee}), do: meeting

  def meeting_view(%MeetingSchema{} = meeting, %__MODULE__{kind: :participant} = recipient) do
    meeting
    |> Map.from_struct()
    |> Map.merge(overlay(recipient))
  end

  defp overlay(recipient) do
    urls = Policy.seat_urls(recipient.management_token)

    %{
      attendee_name: recipient.name,
      attendee_email: recipient.email,
      attendee_phone: recipient.phone,
      attendee_company: recipient.company,
      attendee_message: recipient.message,
      attendee_timezone: recipient.timezone,
      attendee_locale: recipient.locale,
      custom_field_answers: recipient.custom_field_answers,
      cancel_url: urls.cancel_url,
      reschedule_url: urls.reschedule_url
    }
  end

  defp attendee_recipients(%MeetingSchema{attendee_email: email}) when email in [nil, ""], do: []

  defp attendee_recipients(meeting) do
    [
      %__MODULE__{
        kind: :attendee,
        name: meeting.attendee_name,
        email: meeting.attendee_email,
        phone: meeting.attendee_phone,
        company: meeting.attendee_company,
        message: meeting.attendee_message,
        timezone: meeting.attendee_timezone,
        locale: meeting.attendee_locale || "en",
        custom_field_answers: meeting.custom_field_answers || %{}
      }
    ]
  end
end
