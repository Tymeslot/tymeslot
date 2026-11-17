defmodule Tymeslot.Workers.SeriesAnnouncementWorker do
  @moduledoc """
  Announces a booked series: queues its one confirmation to the booker and
  the organiser once every session's video room is ready
  (`Tymeslot.BookingSeries.Notifications.send_series_confirmation/2`).

  The sessions' rooms are made by their own `VideoRoomWorker` jobs after the
  series commits. While one is still being made this job snoozes, so the
  confirmation carries every join link. It waits for 20 snoozes, about ten
  minutes, then sends anyway: a session without its link says it will be in
  the reminder.

  Snoozes are counted with `Tymeslot.Workers.SnoozePolicy.executions/1`:
  from Oban 2.24 a snooze no longer counts as an attempt, so `attempt` alone
  never reaches the bound.

  One job per series while it is still to run (`unique` on the series id).
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 10,
    priority: 0,
    unique: [period: :infinity, keys: [:series_id], states: :incomplete]

  require Logger

  alias Tymeslot.BookingSeries.Notifications
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Workers.SnoozePolicy

  @behaviour ExpectedJobOutcome

  # The snoozes waited for the video rooms before sending without them.
  @max_snoozes 20

  @series_gone "Series not found"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason), do: reason == @series_gone

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"series_id" => series_id}} = job) do
    case SeriesQueries.get(series_id) do
      {:ok, series} ->
        stop_waiting = SnoozePolicy.executions(job) > @max_snoozes
        Notifications.send_series_confirmation(series, stop_waiting: stop_waiting)

      {:error, :not_found} ->
        Logger.warning("Series not found, discarding its announcement", series_id: series_id)
        {:discard, @series_gone}
    end
  end
end
