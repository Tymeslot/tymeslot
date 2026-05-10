defmodule Tymeslot.MeetingPayments.Telemetry do
  @moduledoc """
  Telemetry helpers for the meeting-payments context.

  Three event families are emitted from this module so dashboards and
  log aggregators have a stable contract:

    * `[:tymeslot, :meeting_payments, :stripe, :api, :start | :stop | :exception]`
      — wraps every Stripe API call so latency and error rate per operation
      can be charted. Emitted via `:telemetry.span/3`.
    * `[:tymeslot, :meeting_payments, :webhook, :received, :start | :stop | :exception]`
      — wraps every Connect webhook handler. The `:processed` metadata key
      on `:stop` distinguishes successful processing, idempotent replays
      (which still emit telemetry rather than short-circuit silently), and
      failures.
    * `[:tymeslot, :meeting_payments, :booking_payment, :status_changed]`
      — emitted whenever a `booking_payment` row's `status` field actually
      changes value. Carries the previous and new status atoms plus a
      coarse `reason` so dashboards can attribute funnel transitions.

  This module never queries the database itself; it just shapes telemetry
  payloads. Call sites pass the data they already have.
  """

  @stripe_event [:tymeslot, :meeting_payments, :stripe, :api]
  @webhook_event [:tymeslot, :meeting_payments, :webhook, :received]
  @status_changed_event [:tymeslot, :meeting_payments, :booking_payment, :status_changed]

  @typedoc "Reason for a booking_payment status transition."
  @type status_change_reason ::
          :webhook_paid
          | :webhook_expired
          | :webhook_charge_refunded
          | :webhook_dispute_created
          | :webhook_dispute_closed
          | :host_refund
          | :reconcile

  @typedoc "Webhook processing outcome surfaced as telemetry metadata."
  @type webhook_processed :: :ok | :idempotent_replay | :error

  @doc "Telemetry event prefix for Stripe API calls."
  @spec stripe_event() :: [atom()]
  def stripe_event, do: @stripe_event

  @doc "Telemetry event prefix for webhook handlers."
  @spec webhook_event() :: [atom()]
  def webhook_event, do: @webhook_event

  @doc "Telemetry event for booking_payment status transitions."
  @spec status_changed_event() :: [atom()]
  def status_changed_event, do: @status_changed_event

  @doc """
  Wraps a Stripe API call in a `:telemetry.span/3`. The supplied function
  must return `{:ok, value}` or `{:error, reason}`; either shape is forwarded
  to the caller unchanged. The `:stop` event metadata carries `status: :ok`
  or `status: :error` so dashboards can compute error rate without parsing
  the result tuple.
  """
  @spec span_stripe(atom(), String.t() | nil, (-> result)) :: result
        when result: {:ok, term()} | {:error, term()}
  def span_stripe(operation, account_id, fun)
      when is_atom(operation) and (is_binary(account_id) or is_nil(account_id)) and
             is_function(fun, 0) do
    metadata = %{operation: operation, account_id: account_id}

    :telemetry.span(@stripe_event, metadata, fn ->
      result = fun.()
      {result, Map.put(metadata, :status, status_for(result))}
    end)
  end

  @doc """
  Wraps a webhook handler in a `:telemetry.span/3`. The supplied function
  must return `{result, processed}` where `processed` is one of
  `:ok | :idempotent_replay | :error`; only the `result` is returned to the
  caller. Replays still produce telemetry so traffic stays visible on
  operational dashboards even when most events short-circuit.
  """
  @spec span_webhook(String.t(), (-> {result, webhook_processed()})) :: result
        when result: term()
  def span_webhook(event_type, fun) when is_binary(event_type) and is_function(fun, 0) do
    metadata = %{event_type: event_type}

    :telemetry.span(@webhook_event, metadata, fn ->
      {result, processed} = fun.()
      {result, Map.put(metadata, :processed, processed)}
    end)
  end

  @doc """
  Emits a `[:tymeslot, :meeting_payments, :booking_payment, :status_changed]`
  event when, and only when, `from` and `to` differ. `from` may be `nil`
  for newly inserted rows; `nil → some_status` is treated as a transition.
  """
  @spec emit_status_changed(String.t() | nil, String.t() | nil, status_change_reason()) :: :ok
  def emit_status_changed(from, to, reason)
      when (is_binary(from) or is_nil(from)) and (is_binary(to) or is_nil(to)) and
             is_atom(reason) do
    if from == to do
      :ok
    else
      :telemetry.execute(
        @status_changed_event,
        %{count: 1},
        %{from: to_atom(from), to: to_atom(to), reason: reason}
      )

      :ok
    end
  end

  defp to_atom(nil), do: nil
  defp to_atom(value) when is_binary(value), do: String.to_atom(value)

  defp status_for({:ok, _value}), do: :ok
  defp status_for({:error, _reason}), do: :error
  defp status_for(:ok), do: :ok
  defp status_for(_other), do: :error
end
