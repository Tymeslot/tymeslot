defmodule Tymeslot.Payments.Webhooks.Idempotency do
  @moduledoc """
  The single deduplication policy for verified Stripe webhook events, shared
  by the platform path (`Tymeslot.Payments.Webhooks.Delivery`) and the Connect
  path (`Tymeslot.MeetingPayments.Webhooks.WebhookProcessor`).

  Stripe documents that the same event can be delivered more than once, so a
  redelivery must not repeat the handler's side effects. `with_idempotency/4`
  reserves the event id in `IdempotencyCache`, runs the handler, and settles
  the reservation from the handler's result:

    * success (`:ok` or `{:ok, _}`): marked processed, `{:ok, :processed}`
    * retryable (`{:error, :retry_later}` or `{:error, :retry_later, _}`):
      released so the redelivery runs again, `{:error, :retry_later}`
    * any other result, including a shape no handler is documented to
      return: logged, marked processed so Stripe stops redelivering an event
      that cannot succeed, `{:error, :permanent}`
    * the handler raises, throws or exits: released, then re-raised, so the
      reservation never outlives the attempt

  A delivery arriving while the same event is still in flight is answered
  with `{:error, :retry_later}`; one arriving after it was processed with
  `{:ok, :duplicate}`.

  Callers must verify the event's signature before calling this: reserving an
  unverified id would let a forged payload claim the slot of a genuine event.
  """

  require Logger

  alias Tymeslot.Payments.Webhooks.IdempotencyCache

  @type result :: {:ok, :processed | :duplicate} | {:error, :retry_later | :permanent}

  @doc """
  Runs `fun` at most once for `event_id` and settles the reservation from its
  result (see the module documentation for the outcomes).

  Options:

    * `:payload`: the event to store alongside the processed marker, for
      post-hoc debugging. Omitted by default.
  """
  @spec with_idempotency(String.t(), String.t() | nil, (-> term()), keyword()) :: result()
  def with_idempotency(event_id, event_type, fun, opts \\ [])
      when is_binary(event_id) and is_function(fun, 0) do
    case IdempotencyCache.reserve(event_id) do
      {:ok, :reserved} ->
        run(event_id, event_type, fun, Keyword.get(opts, :payload))

      {:ok, :in_progress} ->
        Logger.info("Stripe webhook event already in progress, asking Stripe to retry",
          event_id: event_id,
          event_type: event_type
        )

        {:error, :retry_later}

      {:ok, :already_processed} ->
        Logger.info("Skipping already processed Stripe webhook event",
          event_id: event_id,
          event_type: event_type
        )

        {:ok, :duplicate}
    end
  end

  defp run(event_id, event_type, fun, payload) do
    started_at = System.monotonic_time(:millisecond)

    result =
      try do
        fun.()
      catch
        kind, reason ->
          IdempotencyCache.release(event_id)

          Logger.error("Stripe webhook handler crashed, reservation released",
            event_id: event_id,
            event_type: event_type,
            error: Exception.format_banner(kind, reason, __STACKTRACE__)
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    duration_ms = System.monotonic_time(:millisecond) - started_at

    settle(classify(result), result, event_id, event_type, payload, duration_ms)
  end

  defp classify(:ok), do: :processed
  defp classify({:ok, _status}), do: :processed
  defp classify({:error, :retry_later}), do: :retry
  defp classify({:error, :retry_later, _message}), do: :retry
  defp classify({:error, _reason}), do: :failed
  defp classify({:error, _reason, _message}), do: :failed
  defp classify(_unexpected), do: :unexpected

  defp settle(:processed, result, event_id, event_type, payload, duration_ms) do
    IdempotencyCache.mark_processed(event_id, event_type, payload)

    Logger.info("Stripe webhook event processed",
      event_id: event_id,
      event_type: event_type,
      status: inspect(result),
      processing_time_ms: duration_ms
    )

    {:ok, :processed}
  end

  defp settle(:retry, result, event_id, event_type, _payload, duration_ms) do
    IdempotencyCache.release(event_id)

    Logger.warning("Stripe webhook event failed transiently, Stripe will retry",
      event_id: event_id,
      event_type: event_type,
      error: inspect(result),
      processing_time_ms: duration_ms
    )

    {:error, :retry_later}
  end

  defp settle(outcome, result, event_id, event_type, payload, duration_ms)
       when outcome in [:failed, :unexpected] do
    IdempotencyCache.mark_processed(event_id, event_type, payload)

    message =
      if outcome == :unexpected,
        do: "Stripe webhook handler returned an unexpected result, treated as permanent",
        else: "Stripe webhook event failed permanently"

    Logger.error(message,
      event_id: event_id,
      event_type: event_type,
      error: inspect(result),
      processing_time_ms: duration_ms
    )

    {:error, :permanent}
  end
end
