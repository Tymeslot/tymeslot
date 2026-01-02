defmodule Tymeslot.Infrastructure.ResilientCall do
  @moduledoc """
  Combines circuit breaker and retry patterns for resilient external calls.
  """

  alias Tymeslot.Infrastructure.{CircuitBreaker, Retry}
  require Logger

  @doc """
  Executes a function with both circuit breaker and retry logic.

  The circuit breaker is checked first. If closed or half-open, the function
  is executed with retry logic. If the circuit is open, it fails immediately.

  ## Options
  - `:breaker` - Name of the circuit breaker to use (required)
  - `:retry_opts` - Options to pass to the retry logic (optional)
  """
  @spec execute((-> any()), keyword()) :: any()
  def execute(fun, opts) when is_function(fun, 0) do
    breaker = Keyword.fetch!(opts, :breaker)
    retry_opts = Keyword.get(opts, :retry_opts, [])

    CircuitBreaker.call(breaker, fn ->
      Retry.with_backoff(fun, retry_opts)
    end)
  end
end
