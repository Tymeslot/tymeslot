defmodule Tymeslot.Integrations.Calendar.CalDAV.Base do
  @moduledoc """
  Shared types and timeout configuration for the CalDAV integration.

  ## Timeout Hierarchy

  Timeouts are configured in a hierarchy to ensure inner operations time out
  before outer ones, providing cleaner error propagation:

      report_timeout (15s) < task_await_timeout (45s) < coalescer_call_timeout (50s)

  With retry logic (max 1 retry, 500ms base delay):
  - Worst case single operation: ~31s (15s + 0.5s delay + 15s retry)
  - This fits within the task_await_timeout (45s)
  - The coalescer_call_timeout (50s) provides buffer for GenServer overhead

  ## Retry Strategy

  Retry logic is applied at specific layers to avoid double-retrying:

  | Function                        | Has Retry? | Notes                      |
  |---------------------------------|------------|----------------------------|
  | `Http.propfind/4`               | ✓          | 2 retries for discovery    |
  | `Http.report/5`                 | ✗          | Low-level, no retry        |
  | `Events.fetch_events/5`         | ✓          | 1 retry, wraps report/5    |
  | `Http.put_event/5`              | ✗          | No retry (write operation) |
  | `Http.delete_event/4`           | ✗          | No retry (write operation) |

  Retryable errors: `:network_error`, `:timeout`, `:server_error`
  """

  @report_timeout_ms 15_000
  @task_await_timeout_ms 45_000
  @coalescer_call_timeout_ms 50_000

  @default_retry_opts [
    max_retries: 1,
    base_delay_ms: 500,
    max_delay_ms: 2_000,
    jitter_factor: 0.1,
    retryable_errors: [:network_error, :timeout, :server_error]
  ]

  @spec report_timeout_ms() :: non_neg_integer()
  def report_timeout_ms, do: @report_timeout_ms

  @spec task_await_timeout_ms() :: non_neg_integer()
  def task_await_timeout_ms, do: @task_await_timeout_ms

  @spec coalescer_call_timeout_ms() :: non_neg_integer()
  def coalescer_call_timeout_ms, do: @coalescer_call_timeout_ms

  @spec default_retry_opts() :: keyword()
  def default_retry_opts, do: @default_retry_opts

  @type client :: %{
          base_url: String.t(),
          username: String.t(),
          password: String.t(),
          calendar_paths: list(String.t()),
          verify_ssl: boolean(),
          provider: atom()
        }

  @type error_reason ::
          :unauthorized
          | :not_found
          | :rate_limited
          | :network_error
          | :invalid_response
          | :server_error
          | String.t()

  @doc """
  Extracts the host component from a URL string.

  Returns `nil` when the URL cannot be parsed or has no host — callers use this
  to key the circuit breaker per server, falling back gracefully when parsing fails.
  """
  @spec extract_host_from_url(String.t()) :: String.t() | nil
  def extract_host_from_url(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _other -> nil
    end
  end
end
