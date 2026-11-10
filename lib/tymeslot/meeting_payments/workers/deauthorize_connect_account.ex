defmodule Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount do
  @moduledoc """
  Revokes the platform's access to a Stripe account a host connected but
  Tymeslot refused, so a declined connection does not linger on their account.

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
