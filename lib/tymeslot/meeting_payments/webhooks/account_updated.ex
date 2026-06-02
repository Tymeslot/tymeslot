defmodule Tymeslot.MeetingPayments.Webhooks.AccountUpdated do
  @moduledoc """
  Handler for the Stripe `account.updated` Connect event.

  Delegates the heavy lifting to `Tymeslot.MeetingPayments.ConnectAccounts.apply_account_event/2`,
  which owns the out-of-order ordering guard via `last_account_event_at`
  and the `disabled_reason`/`charges_enabled` reconciliation. The webhook
  layer unwraps the Stripe envelope, passing the account object plus the
  **event envelope's** `created` as the ordering timestamp.

  Idempotent by virtue of the timestamp guard inside `apply_account_event/2` —
  a replayed event carries the same envelope `created` and produces the same
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

  defp do_handle(%{"data" => %{"object" => %{"id" => account_id} = object}} = event)
       when is_binary(account_id) do
    ConnectAccounts.apply_account_event(object, event_time(event))

    {:ok, :ok}
  end

  defp do_handle(_other), do: {{:error, :invalid_event}, :error}

  # Order events by the event envelope's `created` (the event emission time),
  # NOT the account object's `created`. The account object's `created` is the
  # account-creation timestamp — identical across every account.updated event —
  # so keying ordering off it would drop every update after the first.
  #
  # A missing envelope `created` falls back to the Unix epoch so any subsequent
  # event with a genuine timestamp is always considered newer and never
  # rejected as stale.
  defp event_time(%{"created" => created}) when is_integer(created),
    do: DateTime.from_unix!(created)

  defp event_time(_missing), do: DateTime.from_unix!(0)
end
