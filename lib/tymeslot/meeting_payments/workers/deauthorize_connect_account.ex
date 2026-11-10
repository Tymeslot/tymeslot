defmodule Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount do
  @moduledoc """
  Revokes the platform's access to a Stripe account a host connected through
  OAuth that Tymeslot no longer holds: one it refused, or one the host
  disconnected (or whose owner was deleted), which is scheduled after a delay
  so a checkout session still open can be refunded first.

  An account that has a live row by the time this runs has been connected
  again, by the same host or another, and is left alone.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [
      keys: [:stripe_account_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      period: 60
    ]

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.StripeAdapter

  @doc """
  Schedules the revocation of `stripe_account_id` to run in `delay_seconds`.

  There is one pending job per account: scheduling again while one waits moves
  its time, so the latest caller decides when the revocation is due (`0` for
  now). A job already running or completed does not count, and a new one is
  inserted.
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
      replace: [scheduled: [:scheduled_at]]
    )
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stripe_account_id" => stripe_account_id}})
      when is_binary(stripe_account_id) do
    case ConnectAccountQueries.by_stripe_account_id(stripe_account_id) do
      nil -> revoke(stripe_account_id)
      %ConnectAccountSchema{} -> :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("DeauthorizeConnectAccount missing stripe_account_id",
      args: LogFormat.reason(args)
    )

    {:discard, "missing stripe_account_id"}
  end

  defp revoke(stripe_account_id) do
    case StripeAdapter.deauthorize_account(stripe_account_id) do
      :ok -> :ok
      {:error, :not_connected} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
