defmodule Tymeslot.MeetingPayments.RefundOutcome do
  @moduledoc """
  What one attempt at a refund came to, from Stripe's answer (`RefundExecutor`).

    * `{:succeeded, stripe_refund}`: Stripe accepted the refund. A refund
      still `pending` or `requires_action` at Stripe is money committed
      there, so it counts as made.
    * `{:retry, reason}`: a later attempt may succeed, and Stripe stored no
      answer under the request's idempotency key, so the next attempt sends
      the same key: no answer arrived (a timeout, a dropped connection, in
      which case Stripe may have made the refund), or Stripe turned the
      request away before acting on it (a 409 for a request still in flight
      under the key, a 429). So is a refused or missing API key: Stripe
      acted on nothing, and configuration can fix it.
    * `{:retry_new_key, error}`: a later attempt may succeed, but Stripe
      stored an answer under the key that a resend would only replay: a 5xx,
      after which Stripe may still have made the refund, or an idempotency
      error. The next attempt re-reads Stripe's refunds and sends under a new
      key. With `later_attempt: true`, so is a refusal saying the charge is
      refunded already: an earlier attempt's request may have refunded it
      without Stripe listing that refund yet, so the refusal does not fail
      the refund, and a later attempt finds that refund or, the job's last,
      fails it.
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
          | {:retry_new_key, StripeError.t()}
          | {:failed, String.t()}
          | {:failed, String.t(), String.t()}
          | {:unlistable, StripeError.t()}

  @doc """
  What Stripe's answer to a request for a refund comes to. Options:

    * `:later_attempt` (default `false`): the request follows an earlier
      attempt's, so a refusal saying the charge is refunded already may be
      that earlier request's doing.
  """
  @spec classify({:ok, map()} | {:error, StripeError.t() | :missing_api_key}, [
          {:later_attempt, boolean()}
        ]) :: t()
  def classify(answer, opts \\ [])

  def classify({:ok, %{"status" => status} = refund}, _opts) when status in @committed,
    do: {:succeeded, refund}

  def classify({:ok, %{"status" => status, "id" => id}}, _opts) when status in @ended,
    do: {:failed, "refund_" <> status, id}

  def classify({:error, %StripeError{} = error}, opts) do
    cond do
      unanswered?(error) -> {:retry, error}
      StripeError.retryable?(error) -> {:retry_new_key, error}
      error.type == "idempotency_error" -> {:retry_new_key, error}
      error.code == "charge_already_refunded" and opts[:later_attempt] -> {:retry_new_key, error}
      true -> {:failed, error.code || error.type}
    end
  end

  def classify({:error, :missing_api_key}, _opts), do: {:retry, :missing_api_key}

  defp unanswered?(%StripeError{type: "api_connection_error"}), do: true
  defp unanswered?(%StripeError{status: status}) when status in [409, 429], do: true
  defp unanswered?(error), do: refused_key?(error)

  defp refused_key?(%StripeError{status: 401}), do: true
  defp refused_key?(%StripeError{type: "authentication_error"}), do: true
  defp refused_key?(_error), do: false

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
      refused_key?(error) -> {:retry, error}
      true -> {:unlistable, error}
    end
  end

  def classify_list_error(:missing_api_key), do: {:retry, :missing_api_key}
end
