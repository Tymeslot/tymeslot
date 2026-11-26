defmodule Tymeslot.Integrations.Stripe.RetryPolicy do
  @moduledoc """
  Decides whether `Tymeslot.Integrations.Stripe.Client` tries a failed call
  again, after how long, and how long each attempt may wait. Internal to
  `Tymeslot.Integrations.Stripe`, and pure: time and randomness are passed in.

  The client retries only within one call, for blips a person waiting on the
  result should not see; anything slower is left to the caller's own retry
  (an Oban job, a webhook redelivery). The rules:

  - At most 3 attempts.
  - Stripe's `stripe-should-retry` header, when present, overrides the status.
  - 409 (an idempotency conflict) is retried for every method, and so is a 429
    whose error code is `lock_timeout` (another request held a lock on the
    object). Any other 429 is a rate limit, which a resend a few hundred
    milliseconds later only hits again, so it is final here and left to the
    caller's own retry, as is any other 4xx.
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

  `deadline_ms` bounds the whole call, not only the decision to retry:
  `attempt_timeouts/2` caps each attempt's receive and pool checkout waits at
  the time left, and once none is left no further attempt starts. The connect
  timeout is fixed per connection pool and not capped, so a call may overrun
  its deadline by up to one `connect_timeout`.
  """

  alias Tymeslot.Integrations.Stripe.Request

  @max_attempts 3

  # Finch's own default for waiting on a pooled connection.
  @pool_timeout_ms 5_000

  # Reasons Mint reports before any byte of the request left. A connect
  # timeout is reported as plain `:timeout`, like a receive timeout, so it
  # counts as after-send; the rules above treat both phases alike.
  @connect_reasons [:econnrefused, :nxdomain, :ehostunreach]

  @type outcome ::
          {:response, status :: integer(), headers :: [{String.t(), String.t()}],
           code :: String.t() | nil}
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

  defp retryable?(method, {:response, status, headers, code}) do
    case should_retry_header(headers) do
      "true" -> true
      "false" -> false
      _absent -> retryable_status?(method, status, code)
    end
  end

  defp retryable?(_method, {:transport, phase, _reason}) when phase in [:connect, :after_send],
    do: true

  defp retryable_status?(_method, 409, _code), do: true
  defp retryable_status?(_method, 429, code), do: code == "lock_timeout"
  defp retryable_status?(method, status, _code) when status >= 500, do: method in [:get, :delete]
  defp retryable_status?(_method, _status, _code), do: false

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

  @doc """
  The receive and pool checkout timeouts for an attempt starting `elapsed_ms`
  into the call: the request's own `receive_timeout` and Finch's default pool
  timeout, each capped at the time left before `deadline_ms`. `:expired` when
  no time is left.
  """
  @spec attempt_timeouts(Request.t(), non_neg_integer()) ::
          {:ok, %{receive_timeout: pos_integer(), pool_timeout: pos_integer()}} | :expired
  def attempt_timeouts(%Request{} = request, elapsed_ms) do
    case request.deadline_ms - elapsed_ms do
      remaining when remaining > 0 ->
        {:ok,
         %{
           receive_timeout: min(request.receive_timeout, remaining),
           pool_timeout: min(@pool_timeout_ms, remaining)
         }}

      _none_left ->
        :expired
    end
  end

  @doc """
  Whether a transport failure happened before the request was sent
  (`:connect`) or possibly after (`:after_send`), from its reason.
  """
  @spec transport_phase(term()) :: :connect | :after_send
  def transport_phase(reason) when reason in @connect_reasons, do: :connect
  def transport_phase(_reason), do: :after_send
end
