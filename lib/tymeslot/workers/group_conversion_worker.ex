defmodule Tymeslot.Workers.GroupConversionWorker do
  @moduledoc """
  Migrates a meeting type's existing future bookings into group seats, off
  the request path.

  Enqueued by `Tymeslot.MeetingTypes.update_meeting_type/3` in the same
  transaction as the meeting-type row update, whenever `max_participants`
  crosses from 1 to more than 1: the job can only exist if that update
  committed. The actual migration is `Tymeslot.Meetings.GroupConversion`,
  which processes the convertible bookings in batches; a batch failure
  fails this job so Oban retries it, resuming from the first unconverted
  booking (already-converted bookings are skip-eligible on retry).

  Unique on the full argument set (meeting type and capacity): re-saving the
  same group-bookings limit in quick succession must not queue a second,
  redundant migration on top of one still running. A save that lands on a
  *different* capacity within that window is a distinct job, not a dupe — an
  organiser correcting the limit right after enabling group bookings must
  still have that correction applied; `Tymeslot.Meetings.GroupConversion`
  re-stamps an already-converted meeting's capacity precisely so a second job
  like this one is not wasted.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.GroupConversion

  require Logger

  @unique [period: 300, fields: [:args, :queue]]

  @doc """
  Enqueues the background conversion of `meeting_type_id`'s existing
  bookings to the given `capacity`.
  """
  @spec enqueue(integer(), pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(meeting_type_id, capacity)
      when is_integer(meeting_type_id) and is_integer(capacity) do
    %{"meeting_type_id" => meeting_type_id, "capacity" => capacity}
    |> new(unique: @unique)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"meeting_type_id" => meeting_type_id, "capacity" => capacity}
      }) do
    case GroupConversion.backfill(meeting_type_id, capacity) do
      {:ok, converted} ->
        Logger.info("Group conversion completed",
          meeting_type_id: meeting_type_id,
          converted: converted
        )

        :ok

      {:error, reason} ->
        Logger.warning("Group conversion batch failed, retrying",
          meeting_type_id: meeting_type_id,
          reason: LogFormat.reason(reason)
        )

        {:error, reason}
    end
  end
end
