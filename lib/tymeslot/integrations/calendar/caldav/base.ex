defmodule Tymeslot.Integrations.Calendar.CalDAV.Base do
  @moduledoc """
  Shared types and timeout configuration for the CalDAV integration.

  ## Timeout Hierarchy

  Timeouts are configured in a hierarchy to ensure inner operations time out
  before outer ones, providing cleaner error propagation:

      report_timeout (20s) < task_await_timeout (45s) < coalescer_call_timeout (50s)

  With retry logic (max 1 retry, 500ms base delay):
  - Worst case single operation: ~40.5s (20s + 0.5s delay + 20s retry)
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

  Retryable errors: `:network_error`, `:timeout`, `:server_error`,
  `:service_unavailable`

  ## Related modules

  This module is deliberately inert: it holds vocabulary, not behaviour. The
  work lives in `CalDAV.Http` (wire-level requests), `CalDAV.Events` (event
  CRUD), `CalDAV.Discovery` (calendar discovery) and `CalDAV.Errors` (what a
  failure means).
  """

  # REPORTs can be expensive on servers without time-range indexes (e.g.
  # Radicale's file backend walks every event in the collection to apply
  # narrow filters). 20s per attempt × 1 retry = 40s worst case, which fits
  # inside the 70s circuit breaker GenServer.call budget with headroom.
  # Audit tooling prefers wide fetch ranges specifically to sidestep the
  # narrow-filter slowness.
  @report_timeout_ms 20_000

  # A calendar-query REPORT carries the whole iCalendar text of every event in
  # the window, and is parsed whole into a tree that holds text as charlists
  # at sixteen bytes or more per character, so its memory peaks at many times
  # the size of the XML. Past this budget a response is abandoned
  # mid-transfer and answers `{:error, :response_too_large}`, rather than
  # being downloaded (up to the HTTP client's much larger default) only for
  # the parser to give up on it.
  @max_report_bytes 8 * 1024 * 1024

  # A PROPFIND answers properties, never calendar data: a depth-0 probe is a
  # few hundred bytes. The widest legitimate case is discovery pointed at a
  # calendar collection rather than a home set, which lists every event in it.
  # A SabreDAV member answering the discovery body (its privilege set of ten
  # privileges in a 200 propstat, the calendar-only properties in a 404 one)
  # is about 1 KB, so this holds about 10,000 events: the same as the parser's
  # 10 MB guard did before the listing had a budget of its own, so no
  # collection that connected then is refused now.
  @max_propfind_bytes 10 * 1024 * 1024
  @task_await_timeout_ms 45_000
  @coalescer_call_timeout_ms 50_000

  # One retry, half a second later. Only a failure the HTTP client has
  # already named as transport or server-side is retried; a CalDAV 429 is not,
  # and is left to the sync job's own backoff.
  @retriable_errors [:network_error, :timeout, :server_error, :service_unavailable]
  @default_retry_opts [
    max_attempts: 2,
    initial_delay: 500,
    max_delay: 2_000,
    jitter: 0.1,
    retriable?: &__MODULE__.retriable_error?/1
  ]

  @spec report_timeout_ms() :: non_neg_integer()
  def report_timeout_ms, do: @report_timeout_ms

  @doc "The body budget for a calendar-query REPORT; see `@max_report_bytes`."
  @spec max_report_bytes() :: pos_integer()
  def max_report_bytes, do: @max_report_bytes

  @doc "The body budget for every PROPFIND; see `@max_propfind_bytes`."
  @spec max_propfind_bytes() :: pos_integer()
  def max_propfind_bytes, do: @max_propfind_bytes

  @spec task_await_timeout_ms() :: non_neg_integer()
  def task_await_timeout_ms, do: @task_await_timeout_ms

  @spec coalescer_call_timeout_ms() :: non_neg_integer()
  def coalescer_call_timeout_ms, do: @coalescer_call_timeout_ms

  @doc """
  `Tymeslot.Infrastructure.Retry` options for a CalDAV request: the defaults,
  with any `:retry_opts` in `opts` over them.
  """
  @spec retry_opts(keyword()) :: keyword()
  def retry_opts(opts \\ []),
    do: Keyword.merge(@default_retry_opts, Keyword.get(opts, :retry_opts, []))

  @doc "Whether a CalDAV request that failed with `reason` is retried."
  @spec retriable_error?(term()) :: boolean()
  def retriable_error?(reason), do: reason in @retriable_errors

  @type client :: Tymeslot.Integrations.Calendar.CalDAV.Client.t()

  @type error_reason ::
          :unauthorized
          | :forbidden
          | :not_found
          | :method_not_allowed
          | :precondition_failed
          | :conditional_not_supported
          | :rate_limited
          | :network_error
          | :invalid_response
          # The response body outgrew the request's byte budget and was
          # abandoned mid-transfer.
          | :response_too_large
          | :server_error
          # A 502, 503 or 504: the server is down rather than failing this
          # request.
          | :service_unavailable
          | :server_unresponsive
          | :sync_token_expired
          | :timeout
          # Neither a server-supplied href nor a calendar path and UID were
          # available, so the event names no resource to act on.
          | :unaddressable
          # The server address is, or resolves to, a private one while private
          # addresses are not allowed (`CalDAV.Discovery`).
          | :private_address
          # Credentials were accepted but no calendar collection could be
          # reached; carries the server URL to show the account owner.
          | {:calendar_home_not_found, String.t()}
          | {:calendar_listing_too_large, String.t()}
          | {:unexpected_status, pos_integer()}
          | String.t()
end
