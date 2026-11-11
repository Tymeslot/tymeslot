defmodule Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount do
  @moduledoc """
  Revokes the platform's access to a Stripe account Tymeslot no longer holds:
  one it refused, or one the host disconnected (or whose owner was deleted),
  which is scheduled after a delay so a checkout session still open can be
  refunded first. Accounts created by the platform before OAuth are revoked
  too; should Stripe refuse one as platform-controlled, the job is cancelled
  with a warning, since no retry can change that.

  An account that has a live row by the time this runs has been connected
  again, by the same host or another, and is left alone.

  A failed attempt is retried with Oban's default backoff, which over twenty
  attempts spans days. When the last one fails, an admin alert names the
  account, since Tymeslot would otherwise keep access to an account it has no
  row for with nobody told.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 20,
    unique: [
      keys: [:stripe_account_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      period: 60
    ]

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.StripeAdapter

  @doc """
  Schedules the revocation of `stripe_account_id` to run in `delay_seconds`.

  There is one pending job per account: scheduling again while one waits,
  scheduled or retrying, moves its time, so the latest caller decides when the
  revocation is due (`0` for now). A job already due (`available`) keeps its
  time, as Oban cannot move it back to scheduled. A job already running or
  completed does not count, and a new one is inserted.
  """
  @spec schedule(String.t(), non_neg_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(stripe_account_id, delay_seconds) when is_binary(stripe_account_id) do
    %{stripe_account_id: stripe_account_id}
    |> new(
      schedule_in: delay_seconds,
      unique: [
        period: :infinity,
        keys: [:stripe_account_id],
        states: [:available, :scheduled, :retryable]
      ],
      replace: [scheduled: [:scheduled_at], retryable: [:scheduled_at]]
    )
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stripe_account_id" => stripe_account_id}} = job)
      when is_binary(stripe_account_id) do
    case ConnectAccountQueries.by_stripe_account_id(stripe_account_id) do
      nil -> revoke(job, stripe_account_id)
      %ConnectAccountSchema{} -> :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("DeauthorizeConnectAccount missing stripe_account_id",
      args: LogFormat.reason(args)
    )

    {:discard, "missing stripe_account_id"}
  end

  defp revoke(job, stripe_account_id) do
    case StripeAdapter.deauthorize_account(stripe_account_id) do
      :ok ->
        :ok

      {:error, :not_connected} ->
        :ok

      {:error, :controlled_account} ->
        Logger.warning("Stripe refused to revoke a platform-controlled account",
          stripe_account_id: stripe_account_id
        )

        {:cancel, :controlled_account}

      {:error, :oauth_failed} = error ->
        if job.attempt >= job.max_attempts, do: alert(job, stripe_account_id)
        error
    end
  end

  # The reason is the adapter's own atom, never anything read from Stripe's
  # response, so no detail of it reaches the alert.
  defp alert(job, stripe_account_id) do
    reason = :oauth_failed

    Logger.error("Revoking a Stripe connection failed for good",
      stripe_account_id: stripe_account_id,
      reason: LogFormat.reason(reason)
    )

    AdminAlerts.report(:connect_revocation_failed,
      summary: "Tymeslot's access to a Stripe account could not be revoked",
      reason: reason,
      context: %{stripe_account_id: stripe_account_id, oban_job_id: job.id}
    )
  end
end
