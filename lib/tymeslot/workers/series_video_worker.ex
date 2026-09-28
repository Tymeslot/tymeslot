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

  Unique per series, so a second write before the sync replaces the first
  job's video rather than racing it.
  """
  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 3,
    unique: [
      keys: [:calendar_integration_id, :address],
      states: [:available, :scheduled, :retryable]
    ]

  require Logger

  alias Tymeslot.CalendarGrid.SeriesCarry
  alias Tymeslot.Infrastructure.ExpectedJobOutcome

  @behaviour ExpectedJobOutcome

  # The sync never brought the series back: the documented end of the job,
  # which the organiser repairs by choosing the video again.
  @series_never_cached :series_never_cached

  # 30s, 60s, ... doubling up to ten minutes: about two hours in all.
  @first_snooze_seconds 30
  @longest_snooze_seconds 600
  @max_snoozes 16

  @doc """
  Enqueues the job giving the series `series` (see `SeriesCarry.series/0`)
  the video `{video_integration_id, video_link}`.
  """
  @spec enqueue(SeriesCarry.series(), {pos_integer(), String.t()}) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%{integration_id: integration_id, address: {kind, id}, uid: uid}, {video_id, link}) do
    %{
      "calendar_integration_id" => integration_id,
      "address" => [Atom.to_string(kind), id],
      "series_uid" => uid,
      "video_integration_id" => video_id,
      "video_link" => link
    }
    |> new(replace: [:args])
    |> Oban.insert()
  end

  @impl ExpectedJobOutcome
  def expected_outcome?(reason), do: reason == @series_never_cached

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, meta: meta}) do
    series = %{
      integration_id: args["calendar_integration_id"],
      address: address(args["address"]),
      uid: args["series_uid"]
    }

    case SeriesCarry.put_video(series, {args["video_integration_id"], args["video_link"]}) do
      :ok ->
        :ok

      :not_cached ->
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
