defmodule Tymeslot.BookingSeries.Automation do
  @moduledoc """
  What a booking series tells the host's automations (webhooks, Telegram,
  Slack): one event for the series as a whole when it is confirmed
  (`meeting.series_created`) and when the rest of it is cancelled at once
  (`meeting.series_cancelled`), in place of one `meeting.created` or
  `meeting.cancelled` per session; and, for a series held for the host's
  approval, one when it is requested (`meeting.series_requested`),
  declined (`meeting.series_declined`) or left to expire
  (`meeting.series_request_expired`), in place of the request events of
  each session.

  Each series event is one job (`Tymeslot.Workers.SeriesAutomationWorker`),
  inserted beside the emails it accompanies: the series confirmation, once
  every session's video room exists (`Tymeslot.BookingSeries.Notifications`),
  so the payload carries each session's join link; and the series
  cancellation (`Tymeslot.BookingSeries.Cancel`); the series request
  (`Tymeslot.BookingSeries.Notifications.schedule_series_request/1`) and
  its answer (`Tymeslot.BookingSeries.Approval`). A confirmation run
  again, a retry or a snooze does not announce a series twice: the job is
  unique per series while Oban keeps it, and its fan-out is claimed (see
  the worker for the limits of both).

  The event is about the series' first session, as an event about one
  booking is, and carries a `series` object: its id, mode, session count,
  rhythm, and the sessions it concerns (every session for a booked series,
  the cancelled ones for a cancellation, the held ones for a request, the
  released ones for a decline or an expiry).

  Events about one session of a series (that session cancelled on its own,
  rescheduled) stay per session, carrying the session's place in its
  series (`place/1`).
  """

  alias Tymeslot.BookingSeries.Rule
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Notifications.ChannelFanout
  alias Tymeslot.Notifications.EventTypes
  alias Tymeslot.Notifications.Recipients
  alias Tymeslot.Workers.SeriesAutomationWorker

  # Integrations read English, as their messages are.
  @rule_locale "en"

  @created EventTypes.to_event_type(:meeting_series_created)
  @cancelled EventTypes.to_event_type(:meeting_series_cancelled)
  @requested EventTypes.to_event_type(:meeting_series_requested)
  @declined EventTypes.to_event_type(:meeting_series_declined)
  @expired EventTypes.to_event_type(:meeting_series_request_expired)

  # The events naming the sessions they concern by id, read when the event
  # happened: a request's held sessions are released or confirmed by the
  # time a late job runs.
  @by_ids [@cancelled, @requested, @declined, @expired]

  @typedoc "The `series` object of a series event, JSON-safe as job args store it."
  @type summary :: %{String.t() => term()}

  @typedoc "The `series` object of an event about one session: its place in the series."
  @type place :: %{String.t() => term()}

  @doc """
  The job announcing `series` as booked to the host's automations, for the
  caller to insert beside the series confirmation emails.
  """
  @spec created_job(SeriesSchema.t()) :: Ecto.Changeset.t()
  def created_job(%SeriesSchema{id: series_id}),
    do: SeriesAutomationWorker.new_event(series_id, @created)

  @doc """
  The job announcing that `occurrence_ids` (meeting or seat ids) of
  `series` were cancelled together, for the caller to insert in the
  transaction that cancels them.
  """
  @spec cancelled_job(SeriesSchema.t(), [binary(), ...]) :: Ecto.Changeset.t()
  def cancelled_job(%SeriesSchema{id: series_id}, [_first | _rest] = occurrence_ids),
    do: SeriesAutomationWorker.new_event(series_id, @cancelled, occurrence_ids)

  @doc """
  The job announcing that `series` was requested, its sessions held for the
  host's approval being `meeting_ids`, for the caller to insert in the
  transaction that holds them.
  """
  @spec requested_job(SeriesSchema.t(), [binary(), ...]) :: Ecto.Changeset.t()
  def requested_job(%SeriesSchema{id: series_id}, [_first | _rest] = meeting_ids),
    do: SeriesAutomationWorker.new_event(series_id, @requested, meeting_ids)

  @doc """
  The job announcing that the host declined (`:declined`), or nobody
  answered in time (`:expired`), the request for `series`, whose held
  sessions `meeting_ids` were released.
  """
  @spec request_ended_job(SeriesSchema.t(), :declined | :expired, [binary(), ...]) ::
          Ecto.Changeset.t()
  def request_ended_job(%SeriesSchema{id: series_id}, variant, [_first | _rest] = meeting_ids),
    do: SeriesAutomationWorker.new_event(series_id, request_ended(variant), meeting_ids)

  defp request_ended(:declined), do: @declined
  defp request_ended(:expired), do: @expired

  @doc """
  Fans `event_type` about `series` out to the host's automations: the
  sessions it concerns, read now, with the first of them as the booking the
  event is about. `occurrence_ids` names the sessions of every event but
  `meeting.series_created`, which names the sessions still booked.

  `:ok` when there is nothing to announce: a series cancelled before it was
  confirmed, or no session left to name; and when the host's plan has no
  automations, as for any event. Only a failed check of that plan is
  returned, `{:error, :feature_access_checker_failed}`, for the job to
  retry.
  """
  @spec announce(SeriesSchema.t(), String.t(), [binary()] | nil) ::
          :ok | {:error, :feature_access_checker_failed}
  def announce(%SeriesSchema{cancelled_at: %DateTime{}}, @created, _ids), do: :ok

  def announce(%SeriesSchema{} = series, event_type, occurrence_ids)
      when event_type in [@created | @by_ids] do
    occurrences = SeriesQueries.list_occurrences(series)

    case sessions_for(event_type, occurrences, occurrence_ids) do
      [] ->
        :ok

      [first | _rest] = sessions ->
        meeting = as_booking(first)

        event_type
        |> ChannelFanout.dispatch(meeting,
          series: summary(series, meeting, sessions, occurrences)
        )
        |> retry_only_unchecked()
    end
  end

  @doc """
  The `series` object of an event about one session: the series' id, the
  session's position in it and its session count, or nil for a booking
  outside any series. A seat view (`Tymeslot.Meetings.SeatView`) reads its
  seat's series, since a group meeting row belongs to none.
  """
  @spec place(Meeting.t()) :: place() | nil
  def place(%Meeting{} = meeting) do
    with {series_id, position} when is_binary(series_id) <- membership(meeting),
         {:ok, %SeriesSchema{occurrences_count: count}} <- SeriesQueries.get(series_id) do
      %{"id" => series_id, "position" => position, "count" => count}
    else
      _none -> nil
    end
  end

  # A seat view carries its seat's place; a group meeting row has none.
  defp membership(%Meeting{seat: %{} = seat}),
    do: {Map.get(seat, :series_id), Map.get(seat, :series_position)}

  defp membership(%Meeting{} = meeting), do: {meeting.series_id, meeting.series_position}

  defp retry_only_unchecked({:error, :feature_access_checker_failed} = error), do: error
  defp retry_only_unchecked(_outcome), do: :ok

  # A booked series names the sessions still booked; any other event, the
  # ones it was about.
  defp sessions_for(@created, occurrences, _ids), do: Enum.filter(occurrences, &live?/1)

  defp sessions_for(_by_ids, occurrences, ids) when is_list(ids),
    do: Enum.filter(occurrences, &(&1.id in ids))

  defp sessions_for(_by_ids, _occurrences, _ids), do: []

  defp live?(%Meeting{} = meeting), do: MeetingState.expects_calendar_event?(meeting)

  defp live?(%Participant{meeting: meeting} = seat),
    do: Participant.live?(seat) and MeetingState.expects_calendar_event?(meeting)

  defp as_booking(%Meeting{} = meeting), do: meeting
  defp as_booking(%Participant{meeting: meeting} = seat), do: SeatView.at_event(meeting, seat)

  defp summary(series, first, sessions, occurrences) do
    %{
      "id" => series.id,
      "mode" => Atom.to_string(series.mode),
      "count" => series.occurrences_count,
      "rule" => rule(series, first, occurrences),
      "sessions" => Enum.map(sessions, &session/1)
    }
  end

  # The rhythm read in the organiser's zone, as their messages show times,
  # and as their dashboard words it: with its day and time only while every
  # session still keeps them.
  defp rule(series, first, occurrences) do
    Rule.describe_sessions(
      series,
      Enum.map(occurrences, &occurrence_start/1),
      @rule_locale,
      Recipients.get_organizer_timezone(first)
    )
  end

  defp occurrence_start(%Meeting{start_time: start}), do: start
  defp occurrence_start(%Participant{meeting: %Meeting{start_time: start}}), do: start

  defp session(%Meeting{} = meeting) do
    %{
      "position" => meeting.series_position,
      "meeting_id" => meeting.id,
      "meeting_uid" => meeting.uid,
      "start" => DateTime.to_iso8601(meeting.start_time),
      "end" => DateTime.to_iso8601(meeting.end_time),
      "status" => Atom.to_string(meeting.status),
      "join_url" => meeting.meeting_url
    }
  end

  defp session(%Participant{meeting: meeting} = seat) do
    seen = Recipient.meeting_as_seen_by(meeting, seat)

    meeting
    |> session()
    |> Map.merge(%{
      "position" => seat.series_position,
      "seat_id" => seat.id,
      "status" => seat_status(seat, meeting),
      "join_url" => seen.meeting_url
    })
  end

  defp seat_status(%Participant{cancelled_at: nil}, meeting), do: Atom.to_string(meeting.status)
  defp seat_status(%Participant{}, _meeting), do: "cancelled"
end
