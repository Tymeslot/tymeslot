defmodule Tymeslot.Infrastructure.Retry do
  @moduledoc """
  Provides retry logic with exponential backoff for external service calls.
  """

  require Logger

  @default_opts [
    max_attempts: 3,
    # 1 second
    initial_delay: 1000,
    # 16 seconds
    max_delay: 16_000,
    jitter: true
  ]

  @doc """
  Executes a function with retry logic and exponential backoff.

  ## Options
    * `:max_attempts` - Maximum number of attempts (default: 3)
    * `:initial_delay` - Initial delay in milliseconds (default: 1000)
    * `:max_delay` - Maximum delay in milliseconds (default: 16000)
    * `:jitter` - Whether to add random jitter to delays (default: true)
    * `:retriable?` - Function to determine if error is retriable (default: checks for network/timeout errors)

  ## Examples

      iex> Retry.with_backoff(fn -> Calendar.create_event(data) end)
      {:ok, result}

      iex> Retry.with_backoff(fn -> Calendar.get_events() end, max_attempts: 5)
      {:error, :max_attempts_exceeded}
  """
  @spec with_backoff((-> any), Keyword.t()) :: any
  def with_backoff(fun, opts \\ []) when is_function(fun, 0) do
    opts =
      @default_opts
      |> Keyword.merge(opts)
      |> Keyword.put_new(:retriable?, &default_retriable?/1)

    do_retry(fun, 1, opts)
  end

  defp do_retry(fun, attempt, opts) do
    case fun.() do
      {:ok, _} = success ->
        success

      {:error, reason} ->
        handle_retry_result(reason, fun, attempt, opts)

      # Handle cases where function returns :error atom directly
      :error ->
        if attempt >= opts[:max_attempts] do
          {:error, :max_attempts_exceeded}
        else
          delay = calculate_delay(attempt, opts)
          Process.sleep(delay)
          do_retry(fun, attempt + 1, opts)
        end

      other ->
        # For non-standard returns, don't retry
        other
    end
  end

  defp handle_retry_result(reason, fun, attempt, opts) do
    if attempt >= opts[:max_attempts] do
      Logger.warning("Max retry attempts exceeded",
        attempt: attempt,
        max_attempts: opts[:max_attempts],
        error: inspect(reason)
      )

      {:error, :max_attempts_exceeded}
    else
      if opts[:retriable?].(reason) do
        delay = calculate_delay(attempt, opts)

        Logger.info("Retrying after error",
          attempt: attempt,
          max_attempts: opts[:max_attempts],
          delay_ms: delay,
          error: inspect(reason)
        )

        Process.sleep(delay)
        do_retry(fun, attempt + 1, opts)
      else
        Logger.debug("Error is not retriable", error: inspect(reason))
        {:error, reason}
      end
    end
  end

  defp calculate_delay(attempt, opts) do
    base_delay = opts[:initial_delay] * :math.pow(2, attempt - 1)
    delay = min(round(base_delay), opts[:max_delay])

    if opts[:jitter] do
      # Add random jitter (±25% of delay)
      jitter_range = round(delay * 0.25)
      delay + :rand.uniform(jitter_range * 2) - jitter_range
    else
      delay
    end
  end

  # Default function to determine if an error is retriable
  defp default_retriable?(reason) when is_binary(reason) do
    retriable_patterns = [
      "timeout",
      "connection refused",
      "socket closed",
      "no route to host",
      "network is unreachable",
      "HTTP request failed",
      "502",
      "503",
      "504"
    ]

    down = String.downcase(reason)
    Enum.any?(retriable_patterns, fn pattern -> String.contains?(down, pattern) end)
  end

  defp default_retriable?(%HTTPoison.Error{reason: reason}) do
    retriable_reasons = [
      :timeout,
      :connect_timeout,
      :closed,
      :econnrefused,
      :ehostunreach,
      :enetunreach
    ]

    reason in retriable_reasons
  end

  defp default_retriable?(_), do: false
end
