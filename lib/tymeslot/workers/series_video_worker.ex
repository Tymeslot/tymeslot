defmodule Tymeslot.Workers.SeriesVideoWorker do
  @moduledoc """
  Gives the occurrences of a recurring series the series' video once a sync
  has cached them.

  A sync never writes a row's `video_link` or `video_integration_id`, so the
  occurrences it caches for a series whose rows were dropped (an edit of every
  occurrence, a split, a move to another calendar) or never cached (a series
  just created) come without the video the grid gave the series.
  `Tymeslot.CalendarGrid.SeriesCarry` hands the video over here, with where
  the series now lives, and this job gives it to every cached occurrence of
  the series without a video of its own
  (`Tymeslot.CalendarGrid.SeriesCarry.put_video/2`).

  The sync runs on its own, usually within seconds, so the job looks as soon
  as it is enqueued and, while nothing of the series is cached yet, snoozes
  and looks again, less often each time, for about two hours
  (`@max_snoozes`). A sync that has not brought the series back by then (an
  integration that cannot sync, a series outside the synced range) never
  will, and the job is discarded; the organiser can still choose the video
  again, which reuses a recorded room of the series
  (`Tymeslot.CalendarGrid.EventVideo.change_event_video/3`).

  Unique per series for as long as its job is waiting, snoozing or running
  (`period: :infinity`: the job snoozes for up to two hours, far past Oban's
  default 60-second window), so a second write replaces the first job's
  video rather than racing it with a job of its own. A write that lands
  while the job runs replaces its args, and the job, once that run has
  succeeded, runs once more with them (`SyncRequest.rerun_if_requested/2`).
  An `:executing` row left behind by a node that stopped is not folded into
  past half an hour (`SyncRequest.insert_unique/3`): the write gets a job of
  its own rather than waiting hours for the row's rescue, or being lost with
  it when the rescue finds its attempts spent.
  """
  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:calendar_integration_id, :address],
      states: [:available, :scheduled, :retryable, :executing]
    ]

  require Logger

  alias Tymeslot.CalendarGrid.SeriesCarry
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Workers.SyncRequest

  @behaviour ExpectedJobOutcome

  # The sync never brought the series back: the documented end of the job,
  # which the organiser repairs by choosing the video again.
  @series_never_cached :series_never_cached

  # 30s, 60s, ... doubling up to ten minutes: about two hours in all.
  @first_snooze_seconds 30
  @longest_snooze_seconds 600
  @max_snoozes 16

  # A second write takes over the series' job in whatever state it is in.
  @replace [
    available: [:args],
    scheduled: [:args],
    retryable: [:args],
    executing: [:args]
  ]

  @doc """
  Enqueues the job giving the series `series` (see `SeriesCarry.series/0`)
  the video `{video_integration_id, video_link}`.
  """
  @spec enqueue(SeriesCarry.series(), {pos_integer(), String.t()}) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%{integration_id: integration_id, address: {kind, id}, uid: uid}, {video_id, link}) do
    args = %{
      "calendar_integration_id" => integration_id,
      "address" => [Atom.to_string(kind), id],
      "series_uid" => uid,
      "video_integration_id" => video_id,
      "video_link" => link
    }

    SyncRequest.insert_unique(__MODULE__, args, replace: @replace)
  end

  @impl ExpectedJobOutcome
  def expected_outcome?(reason), do: reason == @series_never_cached

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, meta: meta} = job) do
    series = %{
      integration_id: args["calendar_integration_id"],
      address: address(args["address"]),
      uid: args["series_uid"]
    }

    case SeriesCarry.put_video(series, {args["video_integration_id"], args["video_link"]}) do
      :ok ->
        SyncRequest.rerun_if_requested(:ok, job)

      :not_cached ->
        # Snoozes only, not `SnoozePolicy.executions/1`: this ladder waits for
        # a sync to cache the series, which is all `@max_snoozes` bounds, and a
        # failed attempt in between must not shorten the wait. Oban (2.24 and
        # later) counts each snooze in `meta["snoozed"]`.
        snoozed = Map.get(meta, "snoozed", 0)

        if snoozed < @max_snoozes do
          {:snooze, min(@first_snooze_seconds * Integer.pow(2, snoozed), @longest_snooze_seconds)}
        else
          Logger.info("A series' video was not carried: no sync cached the series",
            calendar_integration_id: series.integration_id
          )

          {:discard, @series_never_cached}
        end
    end
  end

  defp address(["master", id]), do: {:master, id}
  defp address(["resource", href]), do: {:resource, href}
end
