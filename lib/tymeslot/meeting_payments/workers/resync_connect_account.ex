defmodule Tymeslot.MeetingPayments.Workers.ResyncConnectAccount do
  @moduledoc """
  Pulls the latest state of a connected Stripe account and reconciles the
  local `connect_accounts` row.

  Triggered when the host returns from the Stripe onboarding flow
  (the `?return=1` and `?refresh=1` redirects on `/dashboard/payments`),
  so the dashboard reflects the new capability flags without having to
  wait for the next `account.updated` webhook.

  Delegates the heavy lifting to `ConnectAccounts.apply_account_event/2`,
  which owns the timestamp ordering guard and the restriction-email
  side effect.
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
  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.StripeAdapter

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stripe_account_id" => stripe_account_id}})
      when is_binary(stripe_account_id) do
    # Taken before the fetch, so an event emitted while it is in flight is not
    # dropped as older than a snapshot that may not include it. An
    # account.updated webhook emitted before this moment but delivered later
    # is still treated as stale.
    read_at = DateTime.utc_now(:second)

    case StripeAdapter.retrieve_account(stripe_account_id) do
      {:ok, account} ->
        ConnectAccounts.apply_account_event(account, read_at)

      {:error, reason} ->
        Logger.warning("ResyncConnectAccount could not retrieve Stripe account",
          stripe_account_id: stripe_account_id,
          reason: LogFormat.reason(reason)
        )

        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("ResyncConnectAccount missing stripe_account_id", args: LogFormat.reason(args))
    {:discard, "missing stripe_account_id"}
  end
end
