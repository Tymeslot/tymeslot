defmodule Tymeslot.Meetings.CalendarEventConference do
  @moduledoc """
  Putting a booking's Meet conference on its Google event, or taking it off,
  in place.

  A room that is the booking's own calendar event is released by
  `Tymeslot.Meetings.CalendarEventSync.replace/3`. Outlook keeps a Teams
  meeting on its event for good, so an Outlook event is replaced with a new
  one. A Google event cannot be: its id is derived from the booking's
  calendar UID, so the replacement would be refused as the old event's
  duplicate. Google takes a conference off an event in place instead: the
  event is written with `conferenceDataVersion=1` and no `conferenceData`
  (`Tymeslot.Integrations.Calendar.Google.ConferenceData.remove/0`).

  An event written before its booking was put on Meet (a booking moved onto
  Meet, or back to it once its Meet was taken off) is asked for one in place
  in the same way (`request_under_lock/2`). Both writes run under the
  meeting's conference lock (`MeetingQueries.lock_event_conference/1`), so a
  removal and a request queued by two moves never interleave.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.Google.ConferenceData
  alias Tymeslot.Integrations.Calendar.Management, as: CalendarManagement
  alias Tymeslot.Integrations.MeetingProvisioning
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.{CalendarEventCache, MeetingQueries, MeetingSchema, MeetingState}
  alias Tymeslot.Repo

  @doc "Whether the meeting's calendar event is a Google event."
  @spec google?(map()) :: boolean()
  def google?(%{calendar_integration_id: cal_id, organizer_user_id: user_id})
      when is_integer(cal_id) and is_integer(user_id) do
    match?(
      {:ok, %{provider: "google"}},
      CalendarManagement.fetch_integration_for_user(cal_id, user_id)
    )
  end

  def google?(_meeting), do: false

  @doc """
  Takes the Meet conference off the Google event of the meeting `meeting_id`,
  as the meeting stands once its conference lock is held
  (`MeetingQueries.lock_event_conference/1`): only when `decide` answers
  `:clear` for it, and `{:skipped, answer}` for any other answer.

  Taking the conference off keeps the event id, so a booking moved back to
  Meet while the write is in flight could have its video job read the Meet
  just before it goes and take it as the booking's room. The video job waits
  for this lock before it reads the event
  (`MeetingProvisioning.booking_room_placement/1`), so it reads the event as
  the write left it, and a move back read here keeps the conference. Nothing
  else waits for the lock: a cancel or a reschedule never waits on Google,
  as it would on the meeting's row lock.

  A meeting gone meanwhile is `{:error, :meeting_not_found}`. A transaction
  that fails to commit (a failed cache write-through aborts it) is returned
  as its error, for the job to retry.
  """
  @spec clear_under_lock(String.t(), (MeetingSchema.t() -> :clear | answer)) ::
          :ok | {:skipped, answer} | {:error, term()}
        when answer: term()
  def clear_under_lock(meeting_id, decide) do
    under_lock(meeting_id, fn meeting ->
      case decide.(meeting) do
        :clear -> clear_unless_retaken(meeting)
        answer -> {:skipped, answer}
      end
    end)
  end

  @doc """
  Asks the Google event `event_id` of the meeting `meeting_id` for a Meet
  conference, as the meeting stands once its conference lock is held: only
  while the meeting is still on a Meet its event carries
  (`MeetingProvisioning.booking_meet_on_event?/1`), still has `event_id` as
  its event and has no room yet. Otherwise `{:skipped, :changed}`.

  The request goes out as `ConferenceData.booking_create_request/0`, so a
  later move off Meet recognises the conference as the booking's and takes
  it off again, and the video job waiting for the Meet times its wait from
  the request. Errors are as for `clear_under_lock/2`, plus the calendar's
  own refusal (`:conference_refused` for a calendar that allows no Meet).
  """
  @spec request_under_lock(String.t(), String.t()) ::
          :ok | {:skipped, :changed} | {:error, term()}
  def request_under_lock(meeting_id, event_id) do
    under_lock(meeting_id, fn meeting ->
      if awaits_event_meet?(meeting, event_id),
        do: request(meeting),
        else: {:skipped, :changed}
    end)
  end

  defp under_lock(meeting_id, fun) do
    transaction =
      Repo.transaction(fn ->
        MeetingQueries.lock_event_conference(meeting_id)

        case MeetingQueries.get_meeting(meeting_id) do
          {:ok, meeting} -> fun.(meeting)
          {:error, :not_found} -> {:error, :meeting_not_found}
        end
      end)

    case transaction do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp awaits_event_meet?(
         %MeetingSchema{provider_event_id: event_id, video_room_id: nil} = meeting,
         event_id
       ),
       do:
         MeetingState.expects_calendar_event?(meeting) and
           MeetingProvisioning.booking_meet_on_event?(meeting)

  defp awaits_event_meet?(_meeting, _event_id), do: false

  # The meeting back on a Meet its event carries
  # (`MeetingProvisioning.booking_meet_on_event?/1`) keeps it: its video job
  # takes that conference as the booking's room.
  defp clear_unless_retaken(meeting) do
    if MeetingProvisioning.booking_meet_on_event?(meeting) do
      Logger.info("Meeting is back on the Meet its calendar event carries, keeping it",
        meeting_id: meeting.id
      )

      :ok
    else
      clear(meeting)
    end
  end

  # Writes the meeting's event as it stands, without a conference. An event
  # Google no longer has carries no conference either, so it counts as done.
  defp clear(meeting) do
    Logger.info("Taking the Meet conference off the calendar event", meeting_id: meeting.id)

    case write_conference(meeting, ConferenceData.remove()) do
      {:error, :not_found} ->
        Logger.info("Calendar event already gone, no conference to take off",
          meeting_id: meeting.id
        )

        :ok

      result ->
        result
    end
  end

  defp request(meeting) do
    Logger.info("Asking the calendar event for a Meet conference", meeting_id: meeting.id)
    write_conference(meeting, ConferenceData.booking_create_request())
  end

  # Writes the meeting's event as it stands, with `conference_data` as its
  # conference change.
  defp write_conference(meeting, conference_data) do
    event_data =
      meeting
      |> CalendarEventBuilder.build_event_data(
        attendees: Meetings.attendees_for_calendar(meeting)
      )
      |> Map.put(:conference_data, conference_data)

    case CalendarEvents.update_event(meeting.provider_event_id, event_data, meeting) do
      {:error, _reason} = error -> error
      _updated -> CalendarEventCache.write_through_update(meeting, event_data)
    end
  end
end
