defmodule Tymeslot.Integrations.HealthCheck.ErrorAnalysis do
  @moduledoc """
  Domain: Failure Intelligence

  Analyzes errors to determine their nature (transient vs hard failures)
  and calculates appropriate recovery strategies. Provides intelligence
  about error patterns and backoff strategies.
  """

  require Logger

  @type error_class :: :transient | :hard
  @type analysis_result :: {:ok, any()} | {:error, any(), error_class()}

  # Transient backoff: 5min → 10 → 20 → 40 → 60min (cap)
  @transient_initial_ms :timer.minutes(5)
  @hard_backoff_ms :timer.hours(1)
  @max_backoff_ms :timer.hours(1)

  # Normal check interval — used to detect the first failure after a healthy run
  @check_interval :timer.minutes(30)

  @doc """
  Analyzes a check result and classifies any errors.
  Returns a tuple suitable for Monitor.update_health/2.
  """
  @spec analyze({:ok, any()} | {:error, any()}, map()) :: analysis_result()
  def analyze({:ok, result}, _health_state) do
    {:ok, result}
  end

  def analyze({:error, reason}, health_state) do
    error_class = classify_error(reason)

    log_error(reason, error_class, health_state)

    {:error, reason, error_class}
  end

  @doc """
  Classifies an error as either transient (temporary, will retry) or
  hard (permanent, requires intervention).
  """
  @spec classify_error(any()) :: error_class()
  def classify_error({:error, :rate_limited}), do: :transient
  def classify_error({:error, :rate_limited, _message}), do: :transient

  def classify_error({:http_error, status, _message}) when status in [408, 425, 429],
    do: :transient

  def classify_error({:http_error, status, _message}) when status >= 500, do: :transient

  def classify_error(reason) when reason in [:timeout, :nxdomain, :econnrefused, :network_error],
    do: :transient

  def classify_error(reason)
      when reason in [:unauthorized, :invalid_credentials, :token_expired],
      do: :hard

  def classify_error({:exception, message}) when is_binary(message),
    do: classify_error(message)

  def classify_error(reason) when is_binary(reason) do
    if String.valid?(reason) do
      reason_downcased = String.downcase(reason)

      cond do
        String.contains?(reason_downcased, "rate limit") -> :transient
        String.contains?(reason_downcased, "rate limited") -> :transient
        String.contains?(reason_downcased, "too many") -> :transient
        String.contains?(reason_downcased, "timeout") -> :transient
        true -> :hard
      end
    else
      :hard
    end
  end

  def classify_error(_reason), do: :hard

  @doc """
  Calculates the next backoff duration based on error class and current health state.

  Transient failures use an exponential backoff starting at 5 minutes:
    5min → 10 → 20 → 40 → 60min (capped)

  Hard failures (auth errors, bad credentials) always use a fixed 60-minute interval
  since retrying quickly is pointless when credentials are invalid.
  """
  @spec calculate_next_backoff(map(), error_class()) :: pos_integer()
  def calculate_next_backoff(%{backoff_ms: current}, :transient)
      when current == @check_interval do
    # Coming from a healthy/normal state (exactly at 30min interval) — start the ramp from initial
    @transient_initial_ms
  end

  def calculate_next_backoff(%{backoff_ms: current}, :transient) do
    min(current * 2, @max_backoff_ms)
  end

  def calculate_next_backoff(_health_state, :hard) do
    @hard_backoff_ms
  end

  # Private Functions

  defp log_error(reason, :transient, health_state) do
    Logger.warning("Integration health check transient failure",
      reason: inspect(reason),
      backoff_ms: calculate_next_backoff(health_state, :transient),
      error_class: :transient
    )
  end

  defp log_error(reason, :hard, health_state) do
    failures = health_state.failures + 1

    Logger.warning("Integration health check failed",
      reason: inspect(reason),
      failures: failures,
      error_class: :hard
    )
  end
end
