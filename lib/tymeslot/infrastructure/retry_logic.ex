defmodule Tymeslot.Infrastructure.RetryLogic do
  @moduledoc """
  Provides retry logic with exponential backoff for handling transient failures.

  **Deprecated:** Prefer `Tymeslot.Infrastructure.Retry` for new code.
  This module remains for CalDAV compatibility but new callers should use
  `Retry.with_backoff/2` which has richer error classification (Mint/Req/Finch
  exception handling) and a simpler API.

  ## Features
  - Exponential backoff with jitter
  - Configurable max retries and delays
  - Circuit breaker integration
  - Selective retry based on error types
  """

  require Logger

  @default_opts [
    max_retries: 3,
    base_delay_ms: 1000,
    max_delay_ms: 30_000,
    jitter_factor: 0.1,
    retryable_errors: [:network_error, :timeout, :server_error]
  ]

  @type retry_opts :: [
          max_retries: non_neg_integer(),
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          jitter_factor: float(),
          retryable_errors: list(atom()),
          await_timeout: timeout()
        ]

  @doc """
  Executes a function with retry logic using exponential backoff.

  ## Options
  - `:max_retries` - Maximum number of retry attempts (default: 3)
  - `:base_delay_ms` - Initial delay in milliseconds (default: 1000)
  - `:max_delay_ms` - Maximum delay in milliseconds (default: 30000)
  - `:jitter_factor` - Random jitter factor 0.0-1.0 (default: 0.1)
  - `:retryable_errors` - List of error atoms that should trigger retry

  ## Examples

      iex> RetryLogic.with_retry(fn -> 
      ...>   {:ok, "success"}
      ...> end)
      {:ok, "success"}
      
      iex> RetryLogic.with_retry(fn ->
      ...>   {:error, :network_error}
      ...> end, max_retries: 2)
      # Will retry up to 2 times with exponential backoff
  """
  @spec with_retry((-> {:ok, any()} | {:error, any()}), retry_opts()) ::
          {:ok, any()} | {:error, any()}
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    opts = Keyword.merge(@default_opts, opts)
    do_retry(fun, 0, opts)
  end

  @doc """
  Executes an async operation with retry logic.

  Similar to `with_retry/2` but designed for async operations that
  return Task references.

  ## Additional option
  - `:await_timeout` — maximum time, in milliseconds (or `:infinity`), to wait
    for each inner `Task` to complete. Defaults to `:infinity`, matching the
    caller's retry budget rather than `Task.await/1`'s 5 s fallback. A timeout
    is converted to `{:error, :timeout}`, which is retryable by default, so
    slow individual attempts are retried rather than crashing the outer task.
  """
  @spec with_retry_async((-> Task.t()), retry_opts()) :: Task.t()
  def with_retry_async(fun, opts \\ []) when is_function(fun, 0) do
    await_timeout = Keyword.get(opts, :await_timeout, :infinity)

    Task.async(fn ->
      with_retry(
        fn ->
          task = fun.()

          try do
            Task.await(task, await_timeout)
          catch
            :exit, {:timeout, _details} ->
              Task.shutdown(task, :brutal_kill)
              {:error, :timeout}
          end
        end,
        opts
      )
    end)
  end

  @doc """
  Calculates the delay for a given retry attempt using exponential backoff.

  The delay increases exponentially with each attempt and includes
  random jitter to prevent thundering herd problems.

  ## Examples

      iex> delay = RetryLogic.calculate_delay(0, 1000, 30000, 0.1)
      iex> delay >= 900 and delay <= 1100
      true
  """
  @spec calculate_delay(non_neg_integer(), non_neg_integer(), non_neg_integer(), float()) ::
          non_neg_integer()
  def calculate_delay(attempt, base_delay_ms, max_delay_ms, jitter_factor) do
    # Calculate exponential delay: base * 2^attempt
    exponential_delay = round(base_delay_ms * :math.pow(2, attempt))

    # Cap at maximum delay
    capped_delay = min(exponential_delay, max_delay_ms)

    # Add jitter to prevent thundering herd
    jitter_range = round(capped_delay * jitter_factor)

    if jitter_range > 0 do
      jitter = :rand.uniform(jitter_range * 2) - jitter_range
      max(0, capped_delay + jitter)
    else
      capped_delay
    end
  end

  @doc """
  Determines if an error is retryable based on configuration.

  ## Examples

      iex> RetryLogic.retryable_error?(:network_error, [:network_error, :timeout])
      true
      
      iex> RetryLogic.retryable_error?(:unauthorized, [:network_error, :timeout])
      false
  """
  @spec retryable_error?(atom() | tuple(), list(atom())) :: boolean()
  def retryable_error?(error, retryable_errors) when is_atom(error) do
    error in retryable_errors
  end

  def retryable_error?({:error, reason}, retryable_errors) when is_atom(reason) do
    reason in retryable_errors
  end

  def retryable_error?({:error, _message}, _retryable_errors) do
    # String errors are generally not retryable
    false
  end

  def retryable_error?(_error, _retryable_errors) do
    false
  end

  # Private functions

  defp do_retry(fun, attempt, opts) do
    max_retries = opts[:max_retries]

    case fun.() do
      {:ok, _result} = success ->
        if attempt > 0, do: Logger.info("Retry succeeded", attempt: attempt)
        success

      {:error, reason} ->
        handle_retry_error(reason, fun, attempt, opts, max_retries)

      other ->
        # Non-standard response, don't retry
        other
    end
  end

  defp handle_retry_error(reason, fun, attempt, opts, max_retries) do
    if attempt < max_retries && retryable_error?(reason, opts[:retryable_errors]) do
      delay =
        calculate_delay(
          attempt,
          opts[:base_delay_ms],
          opts[:max_delay_ms],
          opts[:jitter_factor]
        )

      Logger.warning("Operation failed, retrying",
        attempt: attempt + 1,
        max_retries: max_retries,
        delay_ms: delay,
        error: inspect(reason)
      )

      Process.sleep(delay)
      do_retry(fun, attempt + 1, opts)
    else
      if attempt > 0 do
        Logger.error("Retry exhausted",
          attempts: attempt + 1,
          error: inspect(reason)
        )
      end

      {:error, reason}
    end
  end
end
