defmodule Tymeslot.Workers.SeriesAutomationWorker do
  @moduledoc """
  Tells the host's automations (webhooks, Telegram, Slack) about a booking
  series as a whole: `meeting.series_created` once it is confirmed,
  `meeting.series_cancelled` once the rest of it is cancelled together
  (`Tymeslot.BookingSeries.Automation`).

  The job only schedules the per-integration deliveries, each its own job
  with its own retries, so it has nothing to retry itself beyond a series
  it cannot read.

  Unique per series and event for good, a completed job included: the
  series confirmation can be queued again (an announcement job rescued
  after a node stopped mid-run), and must not announce the series twice.
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 5,
    priority: 2

  require Logger

  alias Tymeslot.BookingSeries.Automation
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.Infrastructure.ExpectedJobOutcome

  @behaviour ExpectedJobOutcome

  @series_gone "Series not found"

  @once_per_series_event [
    period: :infinity,
    keys: [:series_id, :event_type],
    states: [:suspended, :available, :scheduled, :executing, :retryable, :completed]
  ]

  @impl ExpectedJobOutcome
  def expected_outcome?(reason), do: reason == @series_gone

  @doc """
  The job announcing `event_type` about the series `series_id`;
  `occurrence_ids` names the sessions a cancellation cancelled.
  """
  @spec new_event(binary(), String.t(), [binary()] | nil) :: Oban.Job.changeset()
  def new_event(series_id, event_type, occurrence_ids \\ nil) do
    %{"series_id" => series_id, "event_type" => event_type}
    |> put_occurrences(occurrence_ids)
    |> new(unique: @once_per_series_event)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"series_id" => series_id, "event_type" => event_type} = args}) do
    case SeriesQueries.get(series_id) do
      {:ok, series} ->
        Automation.announce(series, event_type, args["occurrence_ids"])

      {:error, :not_found} ->
        Logger.info("Series not found, discarding its automation event",
          series_id: series_id,
          event_type: event_type
        )

        {:discard, @series_gone}
    end
  end

  defp put_occurrences(args, nil), do: args
  defp put_occurrences(args, ids) when is_list(ids), do: Map.put(args, "occurrence_ids", ids)
end
