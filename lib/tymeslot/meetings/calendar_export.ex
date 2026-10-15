defmodule Tymeslot.Meetings.CalendarExport do
  @moduledoc """
  The `.ics` file a booker downloads from the booking page's confirmation
  step: a solo meeting's, under its uid, or a group-booking seat's own,
  under the seat's management token. Built the way the booking emails build
  their calendar content, so the download matches what was emailed.
  """

  alias Tymeslot.Bookings.BookingTitle
  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Meetings.MeetingAccess
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Meetings.SeatLookup
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Notifications.ContentBuilder

  @doc """
  Exports a single meeting as iCalendar (`.ics`) content, scoped to its
  organizer via the same IDOR-safe lookup as
  `Tymeslot.Meetings.get_meeting_by_uid_for_organizer/2`.

  Returns `{:error, :not_found}` for meetings with no live calendar event
  expected right now — cancelled, completed, or under a pending reschedule
  request (`MeetingState.expects_calendar_event?/1`) — so the public download
  URL can't be used to confirm a cancelled booking ever existed, or to
  produce an .ics for a voided time slot.

  A group meeting is refused the same way: its row is the shared slot, and
  each booker's calendar entry is their seat's (`seat/1`).

  Note that nothing writes the `"completed"` status: a booking that has
  happened is still `"confirmed"`, so a past meeting stays exportable and
  only the other two arms of that predicate are reachable today.

  Runs the meeting through `ContentBuilder.build_appointment_details/1` — the
  same transformation the confirmation/reminder emails use for timezone
  conversion, location, and organizer contact info — carrying over the
  description and custom question answers so the download matches what was
  emailed. The attendee's own video join link is preferred over the generic
  meeting URL, and the title is rendered in the attendee's language, since
  the attendee is exporting their own event.

  A held request (`MeetingState.awaiting_approval?/1`) is exportable — it
  occupies its slot — but must not read as a confirmed meeting to whichever
  calendar it lands on, so it is exported with `STATUS:TENTATIVE`.
  """
  @spec meeting(String.t(), integer()) :: {:ok, String.t()} | {:error, :not_found}
  def meeting(uid, organizer_user_id) do
    with {:ok, meeting} <- MeetingAccess.get_meeting_by_uid_for_organizer(uid, organizer_user_id),
         false <- MeetingSchema.group?(meeting),
         true <- exportable?(meeting) do
      {:ok, export_ics(meeting)}
    else
      _not_found_group_or_inactive -> {:error, :not_found}
    end
  end

  @doc """
  Exports one group-booking seat as iCalendar (`.ics`) content, from the
  seat's management token.

  The file is the participant's own calendar entry, the one their emails
  invite them to: the seat's UID (`ParticipantSchema.calendar_uid/1`), their
  name, locale and answers (`Recipient.meeting_as_seen_by/2`). The slot's
  own export (`meeting/2`) refuses a group meeting: the slot is the
  organiser's event, and its file would be a second entry for the booker
  that no later update or cancellation reaches.

  Returns `{:error, :not_found}` for a token naming no live seat, and for a
  seat whose meeting expects no calendar event right now, as
  `meeting/2` does.
  """
  @spec seat(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def seat(token) do
    with {:ok, %{participant: participant, meeting: meeting}} <- SeatLookup.fetch_live_seat(token),
         true <- exportable?(meeting) do
      {:ok, meeting |> Recipient.meeting_as_seen_by(participant) |> export_ics()}
    else
      _no_live_seat_or_inactive -> {:error, :not_found}
    end
  end

  @doc """
  Where the booker of `meeting` downloads its calendar file, from the
  booking page's confirmation step:

    * `{:seat, url}` for a seat view (`Tymeslot.Meetings.SeatView`): the
      seat's own file, `seat/1` behind its management token;
    * `:none` for any other group meeting: its uid names the shared slot,
      which is never a booker's to hold, export or manage;
    * `{:meeting, uid}` for a solo booking, exported by `meeting/2`.
  """
  @spec for_booker(map()) :: {:seat, String.t()} | {:meeting, String.t()} | :none
  def for_booker(meeting) do
    case SeatView.participant_id(meeting) do
      nil -> meeting_calendar(meeting)
      participant_id -> seat_calendar(participant_id)
    end
  end

  defp meeting_calendar(%MeetingSchema{} = meeting) do
    if MeetingSchema.group?(meeting), do: :none, else: {:meeting, meeting.uid}
  end

  defp meeting_calendar(%{uid: uid}) when is_binary(uid), do: {:meeting, uid}
  defp meeting_calendar(_meeting), do: :none

  defp seat_calendar(participant_id) do
    case ParticipantQueries.get(participant_id) do
      {:ok, %ParticipantSchema{management_token: token}} when is_binary(token) ->
        {:seat, Recipient.seat_calendar_url(token)}

      _gone ->
        :none
    end
  end

  defp export_ics(meeting) do
    details =
      meeting
      |> ContentBuilder.build_appointment_details()
      |> Map.merge(%{
        title: BookingTitle.localise(meeting, meeting.attendee_locale),
        description: meeting.description,
        custom_fields_snapshot: meeting.custom_fields_snapshot,
        custom_field_answers: meeting.custom_field_answers,
        meeting_url: meeting.attendee_video_url || meeting.meeting_url,
        status: ics_export_status(meeting)
      })

    IcsGenerator.generate_ics(details, details.attendee_locale)
  end

  defp ics_export_status(meeting) do
    if MeetingState.awaiting_approval?(meeting), do: "TENTATIVE", else: "CONFIRMED"
  end

  defp exportable?(meeting), do: MeetingState.expects_calendar_event?(meeting)
end
