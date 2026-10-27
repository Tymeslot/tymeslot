defmodule Tymeslot.Infrastructure.Retry do
  @moduledoc """
  Retries a call with exponential backoff and jitter while it fails with a
  transient error.

  The function returns `{:ok, _}` or `{:error, reason}`; anything else is
  returned as it is, without retrying. Whether `reason` is worth another
  attempt is decided by `:retriable?`, by default
  `Tymeslot.Infrastructure.BreakerOutcome.transient?/1`, the rule the circuit
  breakers count failures by. When the attempts run out, or the error is not
  retriable, the last `{:error, reason}` is returned, so the caller still
  knows what failed.

  A rate limit that names its wait, `{:rate_limited, seconds}`, is retried
  after that wait (capped at `:max_delay`) rather than the usual backoff, or
  returned at once when the wait is longer than `:max_rate_limit_wait`.
  `retry_after_seconds/1` reads the wait from a 429 response.
  """

  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @default_opts [
    max_attempts: 3,
    initial_delay: 1_000,
    max_delay: 16_000,
    max_rate_limit_wait: :infinity,
    jitter: 0.25,
    retriable?: &BreakerOutcome.transient?/1
  ]

  @type opts :: [
          max_attempts: pos_integer(),
          initial_delay: non_neg_integer(),
          max_delay: non_neg_integer(),
          max_rate_limit_wait: non_neg_integer() | :infinity,
          jitter: float(),
          retriable?: (term() -> boolean())
        ]

  @doc """
  Runs `fun`, retrying it while it returns a retriable `{:error, reason}`.

  ## Options

    * `:max_attempts` - attempts in all, the first included (default 3)
    * `:initial_delay` - delay before the second attempt, in ms (default 1000);
      each later delay doubles
    * `:max_delay` - cap on any one delay, in ms (default 16000)
    * `:max_rate_limit_wait` - the longest wait a rate limit may name, in ms,
      for it to be retried (default `:infinity`). Set it where someone is
      waiting on the answer: past it, waiting less than the provider asked
      only earns another rate limit, so the error is returned instead.
    * `:jitter` - each delay varies by up to this fraction either way
      (default 0.25; 0.0 for none)
    * `:retriable?` - whether an error reason is worth another attempt
      (default `BreakerOutcome.transient?/1`)
  """
  @spec with_backoff((-> result), opts()) :: result when result: term()
  def with_backoff(fun, opts \\ []) when is_function(fun, 0) do
    run(fun, 1, Keyword.merge(@default_opts, opts))
  end

  @doc """
  The delay before attempt `attempt + 1`, in ms: `initial_delay` doubled for
  each attempt after the first, capped at `max_delay`, varied by `jitter`.
  """
  @spec delay(pos_integer(), opts()) :: non_neg_integer()
  def delay(attempt, opts) do
    opts = Keyword.merge(@default_opts, opts)
    capped = min(round(opts[:initial_delay] * :math.pow(2, attempt - 1)), opts[:max_delay])
    spread = round(capped * opts[:jitter])

    if spread > 0,
      do: max(0, capped + :rand.uniform(spread * 2 + 1) - spread - 1),
      else: capped
  end

  @doc """
  The wait a rate-limited `response` names in its `Retry-After` header, in
  seconds, or `nil` when it names none (or names a date).
  """
  @spec retry_after_seconds(map()) :: non_neg_integer() | nil
  def retry_after_seconds(response) do
    with [value | _rest] <- response |> Map.get(:headers, %{}) |> Map.get("retry-after"),
         {seconds, _remainder} when seconds >= 0 <- Integer.parse(value) do
      seconds
    else
      _no_seconds -> nil
    end
  end

  defp run(fun, attempt, opts) do
    case fun.() do
      {:error, reason} = error -> retry_or_return(error, reason, fun, attempt, opts)
      result -> result
    end
  end

  defp retry_or_return(error, reason, fun, attempt, opts) do
    cond do
      not opts[:retriable?].(reason) ->
        error

      waits_too_long?(reason, opts[:max_rate_limit_wait]) ->
        error

      attempt >= opts[:max_attempts] ->
        Logger.warning("Retry attempts exhausted",
          attempts: attempt,
          error: LogFormat.reason(reason)
        )

        error

      true ->
        delay = delay_for(reason, attempt, opts)

        Logger.info("Retrying after error",
          attempt: attempt,
          max_attempts: opts[:max_attempts],
          delay_ms: delay,
          error: LogFormat.reason(reason)
        )

        Process.sleep(delay)
        run(fun, attempt + 1, opts)
    end
  end

  defp waits_too_long?({:rate_limited, seconds}, max_wait)
       when is_integer(seconds) and is_integer(max_wait),
       do: seconds * 1_000 > max_wait

  defp waits_too_long?(_reason, _max_wait), do: false

  defp delay_for({:rate_limited, seconds}, _attempt, opts)
       when is_integer(seconds) and seconds >= 0,
       do: min(seconds * 1_000, opts[:max_delay])

  defp delay_for(_reason, attempt, opts), do: delay(attempt, opts)
end
