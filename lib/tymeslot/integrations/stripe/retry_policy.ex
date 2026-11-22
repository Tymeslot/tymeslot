defmodule Tymeslot.Integrations.Stripe.RetryPolicy do
  @moduledoc """
  Decides whether `Tymeslot.Integrations.Stripe.Client` tries a failed call
  again, and after how long. Internal to `Tymeslot.Integrations.Stripe`, and
  pure: time and randomness are passed in.

  The client retries only within one call, for blips a person waiting on the
  result should not see; anything slower is left to the caller's own retry
  (an Oban job, a webhook redelivery). The rules:

  - At most 3 attempts.
  - Stripe's `stripe-should-retry` header, when present, overrides the status.
  - 409 (an idempotency conflict) and 429 are retried for every method; any
    other 4xx is final.
  - A 5xx is retried for GET and DELETE only. Stripe stores a POST's 5xx
    against its idempotency key and replays it for 24 hours, so sending the
    same POST again gets the same answer.
  - A transport failure is retried for every method, before or after the
    request was sent: GET and DELETE are idempotent, and every POST carries an
    idempotency key, so a resend replays Stripe's real result.
  - A retry happens only if it can finish inside the request's `deadline_ms`,
    assuming the next attempt takes as long as the last one (at least 1 ms).

  The delay is `base_ms * 2 ** (attempt - 1)`, capped at `4 * base_ms`, then
  scaled by `0.5 + random / 2` so concurrent callers spread out. With 3
  attempts the largest uncapped delay is `2 * base_ms`, so the cap only binds
  if the attempt limit is raised.
  """

  alias Tymeslot.Integrations.Stripe.Request

  @max_attempts 3

  @type outcome ::
          {:response, status :: integer(), headers :: [{String.t(), String.t()}]}
          | {:transport, phase :: :connect | :after_send, reason :: term()}

  @type inputs :: %{
          outcome: outcome(),
          attempt: pos_integer(),
          elapsed_ms: non_neg_integer(),
          last_attempt_ms: non_neg_integer(),
          random: float(),
          base_ms: non_neg_integer()
        }

  @doc """
  `{:retry, delay_ms}` or `:stop` for the attempt that just finished.

  `attempt` is that attempt's 1-based number, `elapsed_ms` the time since the
  call started, `last_attempt_ms` how long the attempt took, and `random` a
  float in `0.0..1.0`.
  """
  @spec decide(Request.t(), inputs()) :: {:retry, non_neg_integer()} | :stop
  def decide(%Request{}, %{attempt: attempt}) when attempt >= @max_attempts, do: :stop

  def decide(%Request{} = request, %{outcome: outcome} = inputs) do
    if retryable?(request.method, outcome), do: within_deadline(request, inputs), else: :stop
  end

  defp retryable?(method, {:response, status, headers}) do
    case should_retry_header(headers) do
      "true" -> true
      "false" -> false
      _absent -> retryable_status?(method, status)
    end
  end

  defp retryable?(_method, {:transport, phase, _reason}) when phase in [:connect, :after_send],
    do: true

  defp retryable_status?(_method, status) when status in [409, 429], do: true
  defp retryable_status?(method, status) when status >= 500, do: method in [:get, :delete]
  defp retryable_status?(_method, _status), do: false

  defp should_retry_header(headers) do
    Enum.find_value(headers, fn {name, value} -> name == "stripe-should-retry" && value end)
  end

  defp within_deadline(request, inputs) do
    delay = delay(inputs)

    if inputs.elapsed_ms + delay + max(inputs.last_attempt_ms, 1) <= request.deadline_ms,
      do: {:retry, delay},
      else: :stop
  end

  defp delay(%{attempt: attempt, base_ms: base_ms, random: random}) do
    backoff = min(base_ms * 2 ** (attempt - 1), 4 * base_ms)
    round(backoff * (0.5 + random / 2))
  end
end
