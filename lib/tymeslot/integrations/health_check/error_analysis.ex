defmodule Tymeslot.Integrations.HealthCheck.ErrorAnalysis do
  @moduledoc """
  Domain: Failure Intelligence

  Analyzes errors to determine their nature (transient vs hard failures)
  and calculates appropriate recovery strategies. Provides intelligence
  about error patterns and backoff strategies.
  """

  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @type error_class :: :transient | :hard
  @type analysis_result :: {:ok, any()} | {:error, any(), error_class()}

  # Transient backoff: 5min → 10 → 20 → 40 → 60min (cap)
  @transient_initial_ms :timer.minutes(5)
  @hard_backoff_ms :timer.hours(1)
  @max_backoff_ms :timer.hours(1)

  @doc """
  Analyzes a check result and classifies any errors.
  Returns a tuple suitable for Monitor.update_health/2.

  A failure is logged once, as a warning carrying `metadata` (the
  integration's type, id and provider).
  """
  @spec analyze({:ok, any()} | {:error, any()}, map(), keyword()) :: analysis_result()
  def analyze(check_result, health_state, metadata \\ [])

  def analyze({:ok, result}, _health_state, _metadata) do
    {:ok, result}
  end

  def analyze({:error, reason}, health_state, metadata) do
    error_class = classify_error(reason)

    log_error(reason, error_class, health_state, metadata)

    {:error, reason, error_class}
  end

  @doc """
  Classifies an error as either transient (temporary, will retry) or
  hard (permanent, requires intervention).

  The classifier is intentionally conservative: only errors with a strong,
  recognised "permanent failure" signal are classified as `:hard`. Everything
  else — unknown atoms, opaque server-returned strings, bare integers — is
  classified as `:transient`. This avoids the historical footgun where a
  single weird response page from a CalDAV server (or an unfamiliar localised
  error message) would push an integration to `:unhealthy` after only three
  occurrences when the underlying connection was actually fine.
  """
  @spec classify_error(any()) :: error_class()
  def classify_error({:error, :rate_limited}), do: :transient
  def classify_error({:error, :rate_limited, _message}), do: :transient

  # Belt-and-braces: `HealthCheck.orchestrate_health_check/2` already
  # short-circuits on a `ConnectionProbe` rate-limit refusal before this
  # module ever sees it (a probe that never ran is not a probe that failed),
  # so this clause only matters if some future caller lets one through.
  def classify_error({:rate_limited, _message}), do: :transient

  def classify_error({:http_error, status, _message}) when status in [408, 425, 429],
    do: :transient

  def classify_error({:http_error, status, _message}) when status >= 500, do: :transient

  # 401/403/404 are the canonical "credentials are wrong / your account no longer
  # has access" statuses. The other 4xx codes (400, 405, 410, 422, 423…) are
  # frequently produced by transient server-side states or malformed client
  # requests that recover on retry, so they default to :transient.
  def classify_error({:http_error, status, _message}) when status in [401, 403, 404], do: :hard

  def classify_error({:http_error, _status, _message}), do: :transient

  def classify_error(reason)
      when reason in [:timeout, :nxdomain, :econnrefused, :network_error, :server_error],
      do: :transient

  # A read past Graph's or Google's page cap meets the same calendar, and the
  # same cap, on every retry: waiting does not shorten it.
  def classify_error(:too_many_pages), do: :hard
  def classify_error({:too_many_pages, _message}), do: :hard

  def classify_error({:exception, message}) when is_binary(message),
    do: classify_error(message)

  # A credential the provider refused for good. The same rule as the reauth
  # fast path (`ResponseHandler`) reads, so the badge and the reconnect email
  # cannot disagree on whether an error is permanent.
  def classify_error(reason) when is_atom(reason) do
    if BreakerOutcome.permanent_credential_error?(reason), do: :hard, else: :transient
  end

  def classify_error(reason) when is_binary(reason) do
    if String.valid?(reason) do
      reason_downcased = String.downcase(reason)

      cond do
        String.contains?(reason_downcased, "rate limit") -> :transient
        String.contains?(reason_downcased, "rate limited") -> :transient
        String.contains?(reason_downcased, "too many") -> :transient
        String.contains?(reason_downcased, "timeout") -> :transient
        BreakerOutcome.permanent_credential_error?(reason) -> :hard
        true -> :transient
      end
    else
      :transient
    end
  end

  def classify_error(_reason), do: :transient

  @doc """
  Calculates the next backoff duration based on error class and current health state.

  Transient failures use an exponential backoff starting at 5 minutes:
    5min → 10 → 20 → 40 → 60min (capped)

  The ramp starts on the first failure after a passing probe, which the state
  records as `last_error_class: nil`; any other failure doubles the current
  backoff. (It used to be inferred from the backoff equalling the healthy
  interval, which a first-unhealthy 15-minute probe doubled into, restarting
  the ramp at 5 minutes.)

  Hard failures (auth errors, bad credentials) always use a fixed 60-minute interval
  since retrying quickly is pointless when credentials are invalid.
  """
  @spec calculate_next_backoff(map(), error_class()) :: pos_integer()
  def calculate_next_backoff(%{last_error_class: nil}, :transient), do: @transient_initial_ms

  def calculate_next_backoff(%{backoff_ms: current}, :transient) do
    min(current * 2, @max_backoff_ms)
  end

  def calculate_next_backoff(_health_state, :hard) do
    @hard_backoff_ms
  end

  # Private Functions

  defp log_error(reason, :transient, health_state, metadata) do
    Logger.warning(
      "Integration health check transient failure",
      metadata ++
        [
          reason: LogFormat.reason(reason),
          backoff_ms: calculate_next_backoff(health_state, :transient),
          error_class: :transient
        ]
    )
  end

  defp log_error(reason, :hard, health_state, metadata) do
    Logger.warning(
      "Integration health check failed",
      metadata ++
        [
          reason: LogFormat.reason(reason),
          failures: health_state.failures + 1,
          error_class: :hard
        ]
    )
  end
end
