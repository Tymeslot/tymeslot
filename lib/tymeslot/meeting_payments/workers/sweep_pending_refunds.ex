defmodule Tymeslot.MeetingPayments.Workers.SweepPendingRefunds do
  @moduledoc """
  Cron sweeper that hands every refund still pending ten minutes after it
  was recorded to an `ExecuteRefund` job, so no refund stays pending for
  want of one: a job that ended with the refund still pending (its last
  attempt could not read Stripe's refunds, say, or raised) is followed by a
  fresh one.

  A refund whose job is still waiting or running already has one, and
  `ExecuteRefund`'s uniqueness makes the insert a no-op for it. That
  includes a refund whose charge's refunds Stripe will not list: its job
  waits, snoozed at intervals that grow to a day, rather than ending, so
  the sweep never adds an attempt (and a Stripe call) of its own every run.
  The insert asks nothing of Stripe and sends nothing: the job's attempts
  do, as for any other refund.

  Every refund row is recorded by `Refunds.request_refund/4` together with
  its job, so the first run after this sweeper is deployed finds only
  refunds whose job has stopped short; refunds made before the table
  existed have no row and are never reached.

  Runs every 15 minutes (configured in the Oban crontab).
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 1,
    unique: [period: 60]

  require Logger

  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund

  @grace_seconds 10 * 60

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@grace_seconds, :second)

    resumed =
      cutoff
      |> RefundQueries.pending_ids_recorded_before()
      |> Enum.count(&resume/1)

    if resumed > 0, do: Logger.warning("Pending refunds handed to a new job", count: resumed)
    :ok
  end

  defp resume(refund_id) do
    case Oban.insert(ExecuteRefund.new(%{refund_id: refund_id})) do
      {:ok, %Oban.Job{conflict?: false}} -> true
      {:ok, %Oban.Job{conflict?: true}} -> false
      {:error, _reason} -> false
    end
  end
end
