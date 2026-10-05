defmodule Tymeslot.Meetings.SeatCalendarExport do
  @moduledoc """
  The "Add to calendar" download for one seat of a group meeting.

  Each seat is its own event in its participant's calendar
  (`Tymeslot.Meetings.ParticipantSchema.calendar_uid/1`), so a group booker's
  download is the seat's event, never the shared slot's: the seat's calendar
  UID and SEQUENCE, and the seat's own cancel and reschedule links. It is
  exactly the invitation the seat's confirmation email attached, built by the
  same `Tymeslot.Emails.AppointmentBuilder.from_meeting/3` overlay and
  rendered by `Tymeslot.Integrations.Calendar.IcsGenerator.generate_invitation_ics/2`,
  so the two can never disagree. It names only the seat's own participant,
  never the others on the slot.

  The download is addressed by the seat's management token, the credential
  its participant already holds from that email.
  """

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Meetings.SeatLookup

  @doc """
  The seat behind `token` as iCalendar content.

  `{:error, :not_found}` for a token naming no live seat (unknown, given up
  or moved), and for a seat whose meeting no longer expects a calendar event
  (`MeetingState.expects_calendar_event?/1`), as `Tymeslot.Meetings.calendar_export/2`
  answers for a solo booking.
  """
  @spec export(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def export(token) when is_binary(token) do
    with {:ok, %{participant: participant, meeting: meeting}} <- SeatLookup.fetch_live_seat(token),
         true <- MeetingState.expects_calendar_event?(meeting) do
      details =
        AppointmentBuilder.from_meeting(meeting, Recipient.from_participant(participant), nil)

      {:ok, IcsGenerator.generate_invitation_ics(details, details.attendee_locale)}
    else
      _no_live_seat -> {:error, :not_found}
    end
  end

  def export(_token), do: {:error, :not_found}

  @doc """
  The management token of the live seat `email` has just booked on the group
  meeting `meeting`, so the booking confirmation can offer that seat's own
  download. The booker receives the same token in their confirmation email.

  `{:error, :not_found}` for a solo meeting, and for an address holding no
  live seat on it.
  """
  @spec booker_seat_token(MeetingSchema.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :not_found}
  def booker_seat_token(%MeetingSchema{id: meeting_id} = meeting, email)
      when is_binary(meeting_id) and is_binary(email) do
    with true <- MeetingSchema.group?(meeting),
         {:ok, %{management_token: token}} when is_binary(token) <-
           ParticipantQueries.get_live_by_email(meeting_id, email) do
      {:ok, token}
    else
      _no_seat -> {:error, :not_found}
    end
  end

  def booker_seat_token(_meeting, _email), do: {:error, :not_found}
end
