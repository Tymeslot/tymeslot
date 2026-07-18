defmodule Tymeslot.Bookings.CancelSeat do
  @moduledoc """
  Cancels a single participant's seat on a group meeting, from their
  tokenised management link.

  The participant row is cancelled in a transaction; their guests stop
  counting towards seats (seat maths only counts guests of live
  participants) and their RSVP links go inert (`Tymeslot.Meetings.Guests`
  refuses RSVPs for cancelled participants). After commit:

    * last leaver: the whole meeting is cancelled through the existing
      `Tymeslot.Bookings.Cancel` flow (calendar event deleted, organiser
      notified there). The leaver still gets their own seat-cancellation
      email from here, since they are no longer a live recipient of the
      meeting; the organiser is not emailed twice.
    * seats remain: the host calendar event is refreshed so its participant
      list matches the live participants, and both the participant and the
      organiser are emailed.

  A seat-availability broadcast is published after commit in both cases.
  """

  require Logger

  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo

  @spec execute(String.t()) ::
          {:ok, :seat_cancelled | :meeting_cancelled} | {:error, term()}
  def execute(management_token) when is_binary(management_token) do
    with {:ok, participant} <- ParticipantQueries.get_by_token(management_token),
         :ok <- ensure_live(participant),
         {:ok, meeting} <- MeetingQueries.get_meeting(participant.meeting_id),
         :ok <- ensure_meeting_live(meeting),
         :ok <- Policy.can_cancel_meeting?(meeting) do
      cancel_seat(meeting, participant)
    end
  end

  defp ensure_live(%{cancelled_at: nil}), do: :ok
  defp ensure_live(_participant), do: {:error, :already_cancelled}

  defp ensure_meeting_live(%{status: "cancelled"}), do: {:error, :already_cancelled}
  defp ensure_meeting_live(_meeting), do: :ok

  defp cancel_seat(meeting, participant) do
    transaction_result =
      Repo.transaction(fn ->
        case ParticipantQueries.cancel(participant) do
          {:ok, cancelled} ->
            {cancelled, ParticipantQueries.list_live_for_meeting(meeting.id)}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case transaction_result do
      {:ok, {cancelled, remaining}} ->
        after_commit(meeting, cancelled, remaining)

      {:error, reason} ->
        Logger.error("Failed to cancel seat",
          meeting_id: meeting.id,
          participant_id: participant.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Last leaver: the meeting-level Cancel flow deletes the calendar event and
  # emails the organiser (with no live participants left, its recipient list
  # is empty, so nobody is double-mailed). The leaver's own confirmation is
  # sent from here with notify_organizer: false.
  defp after_commit(meeting, cancelled, []) do
    SeatBroadcast.broadcast_seat_change(meeting.meeting_type_id)
    Events.seat_cancelled(meeting, cancelled, notify_organizer: false)

    case Cancel.execute(meeting) do
      {:ok, _cancelled_meeting} ->
        {:ok, :meeting_cancelled}

      {:error, reason} ->
        # The seat itself is cancelled and freed; log the meeting-level
        # failure but do not fail the participant's action.
        Logger.error("Failed to cancel emptied group meeting",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        {:ok, :meeting_cancelled}
    end
  end

  defp after_commit(meeting, cancelled, _remaining) do
    SeatBroadcast.broadcast_seat_change(meeting.meeting_type_id)
    CalendarJobs.schedule_job(meeting, "update")
    Events.seat_cancelled(meeting, cancelled, notify_organizer: true)
    {:ok, :seat_cancelled}
  end
end
