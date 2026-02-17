defmodule Tymeslot.Payments.RetryHelper do
  @moduledoc """
  Centralized retry logic for payment operations.

  Provides configurable retry behavior with exponential backoff for handling
  transient failures in external API calls (Stripe, etc).

  ## Configuration

  Set in config/config.exs:

      config :tymeslot, :payment_retry,
        max_attempts: 3,
        base_delay_ms: 1000,
        backoff_multiplier: 1

  ## Usage

      RetryHelper.execute_with_retry(fn ->
        Stripe.Customer.create(params, opts)
      end)
  """

  require Logger

  @type retry_result :: {:ok, term()} | {:error, term()}
  @type operation :: (-> retry_result())

  @doc """
  Executes an operation with automatic retry on transient failures.

  ## Options

    * `:max_attempts` - Maximum number of attempts (default: 3)
    * `:base_delay_ms` - Base delay between retries in milliseconds (default: 1000)
    * `:backoff_multiplier` - Multiplier for exponential backoff (default: 1 for linear)
    * `:retryable_error?` - Custom function to determine if an error is retryable

  ## Examples

      # Simple retry
      RetryHelper.execute_with_retry(fn ->
        Stripe.Customer.create(params)
      end)

      # Custom retry config
      RetryHelper.execute_with_retry(
        fn -> external_api_call() end,
        max_attempts: 5,
        base_delay_ms: 2000
      )
  """
  @spec execute_with_retry(operation(), keyword()) :: retry_result()
  def execute_with_retry(operation, opts \\ []) when is_function(operation, 0) do
    max_attempts = Keyword.get(opts, :max_attempts, default_max_attempts())
    base_delay_ms = Keyword.get(opts, :base_delay_ms, default_base_delay_ms())
    backoff_multiplier = Keyword.get(opts, :backoff_multiplier, default_backoff_multiplier())
    retryable_fn = Keyword.get(opts, :retryable_error?, &default_retryable_error?/1)

    do_retry(operation, 1, max_attempts, base_delay_ms, backoff_multiplier, retryable_fn)
  end

  # Private functions

  defp do_retry(operation, attempt, max_attempts, base_delay_ms, backoff_multiplier, retryable_fn) do
    case operation.() do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        handle_error(
          error,
          attempt,
          max_attempts,
          base_delay_ms,
          backoff_multiplier,
          retryable_fn,
          operation
        )
    end
  rescue
    error ->
      handle_exception(
        error,
        attempt,
        max_attempts,
        base_delay_ms,
        backoff_multiplier,
        retryable_fn,
        operation
      )
  catch
    {:error, _reason} = error ->
      error

    thrown_error ->
      handle_exception(
        thrown_error,
        attempt,
        max_attempts,
        base_delay_ms,
        backoff_multiplier,
        retryable_fn,
        operation
      )
  end

  defp handle_error(
         error,
         attempt,
         max_attempts,
         base_delay_ms,
         backoff_multiplier,
         retryable_fn,
         operation
       ) do
    if attempt < max_attempts and retryable_fn.(error) do
      delay = calculate_delay(attempt, base_delay_ms, backoff_multiplier)
      Logger.warning("Retrying operation after #{delay}ms (attempt #{attempt}/#{max_attempts})")
      Process.sleep(delay)

      do_retry(
        operation,
        attempt + 1,
        max_attempts,
        base_delay_ms,
        backoff_multiplier,
        retryable_fn
      )
    else
      log_final_error(error, attempt)
      {:error, error}
    end
  end

  defp handle_exception(
         exception,
         attempt,
         max_attempts,
         base_delay_ms,
         backoff_multiplier,
         retryable_fn,
         operation
       ) do
    # Treat exceptions as retryable errors
    if attempt < max_attempts and retryable_fn.(exception) do
      delay = calculate_delay(attempt, base_delay_ms, backoff_multiplier)

      Logger.warning(
        "Retrying operation after exception (attempt #{attempt}/#{max_attempts}): #{inspect(exception)}"
      )

      Process.sleep(delay)

      do_retry(
        operation,
        attempt + 1,
        max_attempts,
        base_delay_ms,
        backoff_multiplier,
        retryable_fn
      )
    else
      log_final_error(exception, attempt)
      {:error, exception}
    end
  end

  defp calculate_delay(attempt, base_delay_ms, backoff_multiplier) do
    if backoff_multiplier > 1 do
      # Exponential backoff: base_delay * multiplier^(attempt - 1)
      trunc(base_delay_ms * :math.pow(backoff_multiplier, attempt - 1))
    else
      # Linear backoff: base_delay * attempt
      base_delay_ms * attempt
    end
  end

  defp log_final_error(error, attempts) do
    Logger.error("Operation failed after #{attempts} attempts: #{inspect(error)}")
  end

  @doc """
  Default function to determine if an error is retryable.

  Retries on:
  - Network errors (Stripe SDK)
  - 5xx server errors from Stripe
  - RuntimeError and ErlangError exceptions
  """
  @spec default_retryable_error?(any()) :: boolean()
  def default_retryable_error?(%{source: :network}), do: true
  def default_retryable_error?(%{extra: %{http_status: status}}) when status >= 500, do: true
  def default_retryable_error?(%RuntimeError{}), do: true
  def default_retryable_error?(%ErlangError{}), do: true
  def default_retryable_error?(_error), do: false

  # Configuration helpers

  defp default_max_attempts do
    get_in(Application.get_env(:tymeslot, :payment_retry, []), [:max_attempts]) || 3
  end

  defp default_base_delay_ms do
    get_in(Application.get_env(:tymeslot, :payment_retry, []), [:base_delay_ms]) || 1000
  end

  defp default_backoff_multiplier do
    get_in(Application.get_env(:tymeslot, :payment_retry, []), [:backoff_multiplier]) || 1
  end
end
