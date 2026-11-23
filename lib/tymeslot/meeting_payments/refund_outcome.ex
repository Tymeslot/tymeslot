defmodule Tymeslot.MeetingPayments.RefundOutcome do
  @moduledoc """
  What one attempt at a refund came to, from Stripe's answer (`RefundExecutor`).

    * `{:succeeded, stripe_refund}`: Stripe accepted the refund. A refund
      still `pending` or `requires_action` at Stripe is money committed
      there, so it counts as made.
    * `{:retry, reason}`: a later attempt may succeed. An idempotency error
      is one too, since the next attempt re-reads Stripe's refunds and sends
      under a new key; so is a missing API key, which configuration can fix.
    * `{:failed, code}`: Stripe refused the refund; no attempt will turn
      that round.
    * `{:failed, code, stripe_refund_id}`: Stripe made the refund and ended
      it as `failed` or `canceled`, with code `"refund_<status>"`. The id is
      recorded with the failure, which marks it as Stripe's own verdict on
      that refund, so a later report of it as made is known to be older.
  """

  alias Tymeslot.Integrations.Stripe.Error, as: StripeError

  @committed ["succeeded", "pending", "requires_action"]
  @ended ["failed", "canceled"]

  @type t ::
          {:succeeded, map()}
          | {:retry, StripeError.t() | :missing_api_key}
          | {:failed, String.t()}
          | {:failed, String.t(), String.t()}
          | {:unlistable, StripeError.t()}

  @spec classify({:ok, map()} | {:error, StripeError.t() | :missing_api_key}) :: t()
  def classify({:ok, %{"status" => status} = refund}) when status in @committed,
    do: {:succeeded, refund}

  def classify({:ok, %{"status" => status, "id" => id}}) when status in @ended,
    do: {:failed, "refund_" <> status, id}

  def classify({:error, %StripeError{} = error}) do
    cond do
      StripeError.retryable?(error) -> {:retry, error}
      error.type == "idempotency_error" -> {:retry, error}
      true -> {:failed, error.code || error.type}
    end
  end

  def classify({:error, :missing_api_key}), do: {:retry, :missing_api_key}

  @doc """
  What a failed read of the charge's refunds comes to. The read is made
  because an earlier request may have refunded, so it never fails the
  refund: that would free its share of the balance for a second refund.
  One a later read can get past is retried, as is a refused API key, which
  configuration can fix; any other refusal (a Connect account that revoked
  access, say) is `{:unlistable, error}`, the refund left pending for a
  person to look at.
  """
  @spec classify_list_error(StripeError.t() | :missing_api_key) :: t()
  def classify_list_error(%StripeError{} = error) do
    cond do
      StripeError.retryable?(error) -> {:retry, error}
      error.status == 401 or error.type == "authentication_error" -> {:retry, error}
      true -> {:unlistable, error}
    end
  end

  def classify_list_error(:missing_api_key), do: {:retry, :missing_api_key}
end
