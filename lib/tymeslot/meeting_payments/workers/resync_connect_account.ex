defmodule Tymeslot.MeetingPayments.Workers.ResyncConnectAccount do
  @moduledoc """
  Pulls the latest state of a connected Stripe account and reconciles the
  local `connect_accounts` row.

  Triggered when the host returns to `/dashboard/payments` after connecting
  (`?return=1`, set by the OAuth callback; `?refresh=1` is only still accepted
  for old links, nothing produces it now), so the dashboard reflects the new
  capability flags without having to wait for the next `account.updated`
  webhook.

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

  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Stripe.Accounts
  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.MeetingPayments.ConnectAccounts

  @behaviour ExpectedJobOutcome

  # A deleted or disconnected account is expected; the
  # `account.application.deauthorized` webhook settles its row. Any other
  # permanent refusal (an invalid key, say) stays recorded.
  @impl ExpectedJobOutcome
  def expected_outcome?(reason), do: StripeError.resource_missing?(reason)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stripe_account_id" => stripe_account_id}})
      when is_binary(stripe_account_id) do
    # Taken before the fetch, so an event emitted while it is in flight is not
    # dropped as older than a snapshot that may not include it. An
    # account.updated webhook emitted before this moment but delivered later
    # is still treated as stale.
    read_at = DateTime.utc_now(:second)

    case Accounts.retrieve_connected(stripe_account_id) do
      {:ok, account} ->
        ConnectAccounts.apply_account_event(account, read_at)

      {:error, %StripeError{} = error} ->
        Logger.log(
          if(StripeError.resource_missing?(error), do: :info, else: :warning),
          "ResyncConnectAccount could not retrieve Stripe account",
          stripe_account_id: stripe_account_id,
          operation: error.operation,
          status: error.status,
          code: error.code,
          request_id: error.request_id
        )

        if StripeError.retryable?(error), do: {:error, error}, else: {:cancel, error}

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
