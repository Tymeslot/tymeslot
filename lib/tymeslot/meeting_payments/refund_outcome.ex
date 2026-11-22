defmodule Tymeslot.MeetingPayments.RefundOutcome do
  @moduledoc """
  What one attempt at a refund came to, from Stripe's answer (`RefundExecutor`).

    * `{:succeeded, stripe_refund}`: Stripe accepted the refund. A refund
      still `pending` or `requires_action` at Stripe is money committed
      there, so it counts as made.
    * `{:retry, reason}`: a later attempt may succeed. An idempotency error
      is one too, since the next attempt re-reads Stripe's refunds and sends
      under a new key; so is a missing API key, which configuration can fix.
    * `{:failed, code}`: Stripe refused the refund, or ended it as `failed`
      or `canceled`; no attempt will turn that round.
  """

  alias Tymeslot.Integrations.Stripe.Error, as: StripeError

  @committed ["succeeded", "pending", "requires_action"]
  @ended ["failed", "canceled"]

  @type t ::
          {:succeeded, map()}
          | {:retry, StripeError.t() | :missing_api_key}
          | {:failed, String.t()}

  @spec classify({:ok, map()} | {:error, StripeError.t() | :missing_api_key}) :: t()
  def classify({:ok, %{"status" => status} = refund}) when status in @committed,
    do: {:succeeded, refund}

  def classify({:ok, %{"status" => status}}) when status in @ended,
    do: {:failed, "refund_" <> status}

  def classify({:error, %StripeError{} = error}) do
    cond do
      StripeError.retryable?(error) -> {:retry, error}
      error.type == "idempotency_error" -> {:retry, error}
      true -> {:failed, error.code || error.type}
    end
  end

  def classify({:error, :missing_api_key}), do: {:retry, :missing_api_key}

  @doc """
  What a failed read of the charge's refunds comes to. No refund is sent
  blind, so one a later read can get past is retried; one Stripe refuses
  for good (a Connect account that revoked access, say) fails the refund,
  since no attempt could ever learn whether it was made.
  """
  @spec classify_list_error(StripeError.t() | :missing_api_key) :: t()
  def classify_list_error(%StripeError{} = error) do
    if StripeError.retryable?(error),
      do: {:retry, error},
      else: {:failed, error.code || error.type}
  end

  def classify_list_error(:missing_api_key), do: {:retry, :missing_api_key}
end
