defmodule Tymeslot.MeetingPayments.Workers.ResyncConnectAccount do
  @moduledoc """
  Pulls the latest state of a connected Stripe account and reconciles the
  local `connect_accounts` row.

  Triggered when the host returns from the Stripe Express onboarding flow
  (the `?return=1` and `?refresh=1` redirects on `/dashboard/payments`),
  so the dashboard reflects the new capability flags without having to
  wait for the next `account.updated` webhook.

  Delegates the heavy lifting to `ConnectAccounts.apply_account_event/1`,
  which owns the timestamp ordering guard and the restriction-email
  side effect.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [
      keys: [:stripe_account_id],
      states: [:available, :scheduled, :executing, :retryable],
      period: 60
    ]

  require Logger

  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.StripeAdapter

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stripe_account_id" => stripe_account_id}})
      when is_binary(stripe_account_id) do
    case StripeAdapter.retrieve_account(stripe_account_id) do
      {:ok, account} ->
        ConnectAccounts.apply_account_event(ensure_created(account))

      {:error, reason} ->
        Logger.warning("ResyncConnectAccount could not retrieve Stripe account",
          stripe_account_id: stripe_account_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("ResyncConnectAccount missing stripe_account_id", args: inspect(args))
    {:discard, "missing stripe_account_id"}
  end

  # `apply_account_event/1` requires a `"created"` field for ordering. The
  # Stripe API exposes one on retrieved accounts, but synthesise a fallback
  # so a stripped-down test or future API change cannot crash the worker.
  defp ensure_created(%{"created" => created} = account) when is_integer(created), do: account

  defp ensure_created(account) do
    # Treat a missing `created` field as the oldest possible event (Unix
    # epoch = 0) so any subsequent real Stripe event with a genuine timestamp
    # is always considered newer and never rejected as stale.
    Map.put(account, "created", 0)
  end
end
