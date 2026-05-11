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
  alias Tymeslot.MeetingPayments.Telemetry

  @event_type "account.updated"

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"data" => %{"object" => %{"id" => account_id} = object}})
       when is_binary(account_id) do
    object
    |> ensure_created(get_in(object, ["created"]))
    |> ConnectAccounts.apply_account_event()

    {:ok, :ok}
  end

  defp do_handle(_other), do: {{:error, :invalid_event}, :error}

  defp ensure_created(object, created) when is_integer(created), do: object

  defp ensure_created(object, _missing) do
    Map.put(object, "created", System.os_time(:second))
  end
end
