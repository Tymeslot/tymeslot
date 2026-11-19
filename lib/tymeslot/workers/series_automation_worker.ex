defmodule Tymeslot.Workers.SeriesAutomationWorker do
  @moduledoc """
  Tells the host's automations (webhooks, Telegram, Slack) about a booking
  series as a whole: `meeting.series_created` once it is confirmed,
  `meeting.series_cancelled` once the rest of it is cancelled together, and
  for a series held for approval `meeting.series_requested`,
  `meeting.series_declined` and `meeting.series_request_expired`
  (`Tymeslot.BookingSeries.Automation`).

  The job only schedules the per-integration deliveries, each its own job
  with its own retries, so it has nothing to retry itself beyond a series
  it cannot read or a plan it could not check.

  A `meeting.series_created` job is unique per series while Oban keeps it,
  a completed one included: the series confirmation can be queued again
  (an announcement job rescued after a node stopped mid-run), and must not
  announce the series twice. Oban prunes completed jobs after a week, which
  bounds that guarantee; nothing queues a confirmation that late. The
  request events are unique the same way: a series is requested, and
  answered, once. A `meeting.series_cancelled` job is unique only while
  it is still to run: cancelling the rest of a series happens once, in a
  transaction that finds nothing left to cancel the second time.

  The fan-out itself is claimed (`Tymeslot.Workers.DeliveryClaims`), so
  this job rescued after it scheduled the deliveries does not schedule them
  again. As for any claim, a node stopping between the claim and the end
  of the fan-out leaves the integrations not yet reached unannounced.
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 5,
    priority: 2

  require Logger

  alias Tymeslot.BookingSeries.Automation
  alias Tymeslot.BookingSeries.SeriesQueries
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Workers.DeliveryClaims

  @behaviour ExpectedJobOutcome

  @series_gone "Series not found"

  @series_cancelled "meeting.series_cancelled"

  @still_to_run [:suspended, :available, :scheduled, :executing, :retryable]

  @impl ExpectedJobOutcome
  def expected_outcome?(reason), do: reason == @series_gone

  @doc """
  The job announcing `event_type` about the series `series_id`;
  `occurrence_ids` names the sessions it concerns (all but
  `meeting.series_created`).
  """
  @spec new_event(binary(), String.t(), [binary()] | nil) :: Oban.Job.changeset()
  def new_event(series_id, event_type, occurrence_ids \\ nil) do
    %{"series_id" => series_id, "event_type" => event_type}
    |> put_occurrences(occurrence_ids)
    |> new(
      unique: [period: :infinity, keys: [:series_id, :event_type], states: states(event_type)]
    )
  end

  defp states(@series_cancelled), do: @still_to_run
  defp states(_once_per_series), do: [:completed | @still_to_run]

  @impl Oban.Worker
  def perform(
        %Oban.Job{args: %{"series_id" => series_id, "event_type" => event_type} = args} = job
      ) do
    case SeriesQueries.get(series_id) do
      {:ok, series} ->
        DeliveryClaims.once(job, "series_automation", fn ->
          Automation.announce(series, event_type, args["occurrence_ids"])
        end)

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
