defmodule Tymeslot.Infrastructure.ResilientCall do
  @moduledoc """
  Combines circuit breaker and retry patterns for resilient external calls.
  """

  alias Tymeslot.Infrastructure.{CircuitBreaker, Retry}

  @doc """
  Executes a function with both circuit breaker and retry logic.

  The circuit breaker is checked first. If closed or half-open, the function
  is executed with retry logic. If the circuit is open, it fails immediately.

  ## Options
  - `:breaker` - Name of the circuit breaker to use (required)
  - `:retry_opts` - Options to pass to the retry logic (optional)
  - `:classify` - a `(term() -> BreakerOutcome.outcome())` function, passed
    straight through to `CircuitBreaker.call/3`. Defaults to a classifier
    that treats any surviving `{:error, _}` as `:failure` rather than
    `BreakerOutcome.classify/1`'s narrower default: by the time a result
    reaches here, `Retry.with_backoff/2` has already exhausted every retry
    (or judged the error non-retriable), so an unrecognised error shape is
    not the ambiguous case `BreakerOutcome` is conservative about — it is a
    call this combinator already gave every chance to succeed.
  """
  @spec execute((-> any()), keyword()) :: any()
  def execute(fun, opts) when is_function(fun, 0) do
    breaker = Keyword.fetch!(opts, :breaker)
    retry_opts = Keyword.get(opts, :retry_opts, [])
    classify_fun = Keyword.get(opts, :classify, &default_classify/1)

    CircuitBreaker.call(
      breaker,
      fn -> Retry.with_backoff(fun, retry_opts) end,
      classify: classify_fun
    )
  end

  defp default_classify({:error, _reason}), do: :failure
  defp default_classify(_other), do: :success
end
