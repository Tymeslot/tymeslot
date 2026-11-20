defmodule Tymeslot.Bookings.Workers.RescheduleRequestExpiryWorker do
  @moduledoc """
  Expires one host's reschedule request at its deadline, unless the attendee
  answered it first (`Tymeslot.Bookings.RescheduleRequestExpiry`).

  Queued when the request is made and left in place when it is answered: the
  job names the request by its `requested_at`, so once the attendee has picked
  a new time, or a later request has replaced this one, it finds nothing to
  do and is discarded. `Tymeslot.Bookings.Workers.RescheduleRequestSweepWorker`
  is the backstop for a job that never runs.

  Retrying is safe: the expiry is a guarded transition, so a run after an
  earlier one succeeded, or after the attendee answered, changes nothing.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 315_360_000, fields: [:args, :worker], keys: [:meeting_id, :requested_at]]

  alias Tymeslot.Bookings.RescheduleRequestExpiry
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState

  @behaviour ExpectedJobOutcome

  # Every discard here is a request that no longer needs expiring.
  @meeting_gone "Meeting not found"
  @request_answered "Reschedule request no longer pending"
  @answered_while_expiring "Reschedule request answered while expiring"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do: reason in [@meeting_gone, @request_answered, @answered_while_expiring]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id, "requested_at" => requested_at}}) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} -> expire_if_pending(meeting, requested_at)
      {:error, :not_found} -> {:discard, @meeting_gone}
    end
  end

  defp expire_if_pending(meeting, requested_at) do
    cond do
      not pending?(meeting, requested_at) ->
        {:discard, @request_answered}

      seconds_to_deadline(meeting) > 0 ->
        # Oban runs a job at or after its `scheduled_at`, which is the
        # deadline; this only guards a job that was inserted by hand.
        {:snooze, seconds_to_deadline(meeting)}

      true ->
        expire(meeting)
    end
  end

  defp pending?(%{reschedule_requested_at: %DateTime{} = at} = meeting, requested_at),
    do: MeetingState.awaiting_new_time?(meeting) and DateTime.to_iso8601(at) == requested_at

  defp pending?(_meeting, _requested_at), do: false

  defp seconds_to_deadline(meeting) do
    meeting
    |> MeetingState.reschedule_request_deadline()
    |> DateTime.diff(Clock.utc_now())
  end

  defp expire(meeting) do
    case RescheduleRequestExpiry.expire(meeting) do
      {:ok, _expired} -> :ok
      {:error, :not_lapsed} -> {:discard, @answered_while_expiring}
      {:error, reason} -> {:error, reason}
    end
  end
end
