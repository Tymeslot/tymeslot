defmodule Tymeslot.MeetingPayments.Webhooks.AccountUpdated do
  @moduledoc """
  Handler for the Stripe `account.updated` Connect event.

  Delegates the heavy lifting to `Tymeslot.MeetingPayments.ConnectAccounts.apply_account_event/1`,
  which owns the out-of-order ordering guard via `last_account_event_at`
  and the `disabled_reason`/`charges_enabled` reconciliation. The webhook
  layer just unwraps the Stripe envelope and passes the account object
  through.

  Idempotent by virtue of the timestamp guard inside `apply_account_event/1` —
  a replayed event with the same `created` timestamp produces the same
  end state.
  """

  require Logger

  alias Tymeslot.MeetingPayments.ConnectAccounts

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(%{"data" => %{"object" => %{"id" => account_id} = object}})
      when is_binary(account_id) do
    ConnectAccounts.apply_account_event(object)
  end

  def handle(_other), do: {:error, :invalid_event}
end
