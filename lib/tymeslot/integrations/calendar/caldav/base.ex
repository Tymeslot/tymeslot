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

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalDAV.Http, as: CalDAVHttp
  alias Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder
  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Security.RateLimiter

  require Logger

  # REPORTs can be expensive on servers without time-range indexes (e.g.
  # Radicale's file backend walks every event in the collection to apply
  # narrow filters). 20s per attempt × 1 retry = 40s worst case, which fits
  # inside the 70s circuit breaker GenServer.call budget with headroom.
  # Audit tooling prefers wide fetch ranges specifically to sidestep the
  # narrow-filter slowness.
  @report_timeout_ms 20_000
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
          | :precondition_failed
          | :rate_limited
          | :network_error
          | :invalid_response
          | :server_error
          | :server_unresponsive
          | :timeout
          | String.t()

  # ---------------------------------------------------------------------------
  # HTTP transport delegates
  #
  # These public functions preserve Base's API while delegating the actual HTTP
  # work to CalDAVHttp, the single module responsible for wire-level CalDAV
  # communication.
  # ---------------------------------------------------------------------------

  @doc """
  Performs a PROPFIND request against a CalDAV server.
  """
  @spec propfind(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  defdelegate propfind(url, username, password, opts \\ []), to: CalDAVHttp

  @doc """
  Performs a REPORT request for fetching events.
  """
  @spec report(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  defdelegate report(url, username, password, body, opts \\ []), to: CalDAVHttp

  @doc """
  Performs a PUT request to create or update an event.
  """
  @spec put_event(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  defdelegate put_event(url, username, password, ical_data, opts \\ []), to: CalDAVHttp

  @doc """
  Performs a DELETE request to remove an event.
  """
  @spec delete_event(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  defdelegate delete_event(url, username, password, opts \\ []), to: CalDAVHttp

  @doc """
  Performs a PROPFIND request to fetch the CTag property for a calendar.
  """
  @spec propfind_ctag(String.t(), String.t(), String.t()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  defdelegate propfind_ctag(calendar_url, username, password), to: CalDAVHttp

  @doc """
  Performs a HEAD request to fetch current headers (e.g., ETag) for an event resource.
  """
  @spec head_event(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  defdelegate head_event(url, username, password, opts \\ []), to: CalDAVHttp

  # ---------------------------------------------------------------------------
  # Orchestration — discovery, CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Discovers available calendars on the CalDAV server with circuit breaker protection.
  """
  @spec discover_calendars(client(), keyword()) ::
          {:ok,
           list(%{
             required(:id) => String.t(),
             required(:name) => String.t(),
             required(:href) => String.t(),
             required(:color) => String.t(),
             required(:selected) => boolean()
           })}
          | {:error, error_reason()}
  def discover_calendars(client, opts \\ []) do
    ip_address = Keyword.get(opts, :ip_address, "127.0.0.1")

    with :ok <- check_rate_limit(:discovery, ip_address),
         :ok <- validate_client_url(client.base_url) do
      with_caldav_breaker(client, opts, fn ->
        discovery_url = UrlBuilder.build_discovery_url(client)

        case propfind(discovery_url, client.username, client.password, max_retries: 0) do
          {:ok, %Req.Response{status: 207, body: body}} ->
            parse_calendar_discovery(body, client)

          {:ok, %Req.Response{body: body}} ->
            parse_calendar_discovery(body, client)

          {:error, reason} when reason in [:not_found, :server_error] ->
            # Guessed discovery path failed. Follow RFC 4791:
            # current-user-principal -> calendar-home-set -> calendar list.
            Logger.debug(
              "CalDAV discovery path not found; falling back to RFC 4791 principal discovery",
              reason: reason,
              base_url: client.base_url
            )

            discover_via_rfc4791(client)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  @doc """
  Creates a new event in the calendar.
  """
  @spec create_calendar_event(client(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, error_reason()}
  def create_calendar_event(client, calendar_path, event_data, opts \\ []) do
    with_caldav_breaker(client, opts, fn ->
      uid = event_data[:uid] || generate_uid()
      url = UrlBuilder.build_event_url(client.base_url, calendar_path, uid)

      ical_data = build_ical_data(event_data, uid)

      # Pass timeout options through to put_event for background worker compatibility
      put_opts = Keyword.merge([operation: :create], Keyword.take(opts, [:timeout]))

      case put_event(url, client.username, client.password, ical_data, put_opts) do
        {:ok, %Req.Response{status: status}} when status in [200, 201, 204] ->
          {:ok, uid}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Updates an existing event in the calendar.
  """
  @spec update_calendar_event(client(), String.t(), String.t(), map(), keyword()) ::
          :ok | {:error, error_reason()}
  def update_calendar_event(client, calendar_path, uid, event_data, opts \\ []) do
    with_caldav_breaker(client, opts, fn ->
      url = UrlBuilder.build_event_url(client.base_url, calendar_path, uid)
      ical_data = build_ical_data(Map.put(event_data, :uid, uid), uid)

      etag = get_current_etag(url, client, opts)

      base_put_opts =
        if etag, do: [operation: :update, if_match: etag], else: [operation: :update]

      # Pass timeout options through to put_event
      put_opts = Keyword.merge(base_put_opts, Keyword.take(opts, [:timeout]))

      put_update(url, client, ical_data, put_opts)
    end)
  end

  @doc """
  Deletes an event from the calendar.
  """
  @spec delete_calendar_event(client(), String.t(), String.t(), keyword()) ::
          :ok | {:error, error_reason()}
  def delete_calendar_event(client, calendar_path, uid, opts \\ []) do
    with_caldav_breaker(client, opts, fn ->
      url = UrlBuilder.build_event_url(client.base_url, calendar_path, uid)

      # Pass timeout options through to delete_event
      delete_opts = Keyword.take(opts, [:timeout])

      case delete_event(url, client.username, client.password, delete_opts) do
        {:ok, %Req.Response{}} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers — orchestration support
  # ---------------------------------------------------------------------------

  # Refactored helpers to reduce nesting
  defp get_current_etag(url, client, opts) do
    # Use shorter timeout for HEAD requests since ETag is optional
    # This prevents HEAD from consuming too much of the worker's 90s timeout
    # If HEAD times out, we proceed without ETag (which is safe)
    head_timeout = Keyword.get(opts, :head_timeout, 15_000)
    head_opts = Keyword.put(opts, :timeout, head_timeout)

    case head_event(url, client.username, client.password, head_opts) do
      {:ok, %{headers: headers}} ->
        case Map.get(headers, "etag") do
          [etag | _rest] -> etag
          _other -> nil
        end

      _error ->
        # HEAD failed or timed out - proceed without ETag
        # This is safe as PUT will work without If-Match header
        nil
    end
  end

  defp put_update(url, client, ical_data, put_opts) do
    case put_event(url, client.username, client.password, ical_data, put_opts) do
      {:ok, %Req.Response{status: status}} when status in [200, 201, 204] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # RFC 4791 discovery helpers

  # Full RFC 4791 discovery chain:
  #   1. PROPFIND server root -> current-user-principal href
  #   2. PROPFIND principal URL -> calendar-home-set href
  #   3. PROPFIND calendar-home-set -> list of calendars
  defp discover_via_rfc4791(client) do
    origin_root = UrlBuilder.build_calendar_url(client.base_url, "/")

    with {:ok, %Req.Response{body: principal_xml}} <-
           propfind(origin_root, client.username, client.password,
             body: XmlHandler.build_propfind_request(properties: [:current_user_principal]),
             depth: "0"
           ),
         {:ok, principal_href} <- XmlHandler.parse_current_user_principal(principal_xml),
         principal_url = UrlBuilder.build_calendar_url(client.base_url, principal_href),
         {:ok, %Req.Response{body: home_xml}} <-
           propfind(principal_url, client.username, client.password,
             body: XmlHandler.build_propfind_request(properties: [:calendar_home_set]),
             depth: "0"
           ),
         {:ok, home_href} <- XmlHandler.parse_calendar_home_set(home_xml) do
      home_url = UrlBuilder.build_calendar_url(client.base_url, home_href)

      case propfind(home_url, client.username, client.password) do
        {:ok, %Req.Response{body: cal_xml}} -> parse_calendar_discovery(cal_xml, client)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp with_caldav_breaker(client, opts, fun) when is_function(fun, 0) do
    provider = Map.get(client, :provider, :caldav)
    host = extract_host_from_url(client.base_url)
    opts = Keyword.put(opts, :host, host)
    CalendarCircuitBreaker.with_breaker(provider, opts, fun)
  end

  defp parse_calendar_discovery(xml_body, client) do
    XmlHandler.parse_calendar_discovery(xml_body,
      include_id: true,
      include_selected: false,
      provider: client.provider
    )
  end

  defp build_ical_data(event_data, uid) do
    ICalBuilder.build_simple_event(uid, event_data)
  end

  defp generate_uid do
    ICalBuilder.generate_uid()
  end

  defp check_rate_limit(:discovery, ip_address) do
    case RateLimiter.check_calendar_discovery_rate_limit(ip_address) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, message}
    end
  end

  defp validate_client_url(url) when is_binary(url) do
    with {:ok, {scheme, host}} <- validate_scheme_and_host(url),
         :ok <- enforce_https_if_needed(scheme, host),
         :ok <- check_url_patterns(url) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_client_url(_arg), do: {:error, :invalid_url}

  defp validate_scheme_and_host(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, {scheme, host}}

      _other ->
        {:error, :invalid_url}
    end
  end

  defp enforce_https_if_needed("http", host) do
    if local_or_private_host?(host), do: :ok, else: {:error, :invalid_url}
  end

  defp enforce_https_if_needed(_scheme, _host), do: :ok

  defp check_url_patterns(url) do
    cond do
      String.contains?(url, ["javascript:", "data:", "file:", "ftp:"]) ->
        {:error, :invalid_url}

      String.length(url) > 2000 ->
        {:error, :url_too_long}

      true ->
        :ok
    end
  end

  defp local_or_private_host?(host) do
    downcased = String.downcase(host)

    downcased in ["localhost", "[::1]"] or
      String.starts_with?(downcased, [
        "127.",
        "10.",
        "192.168.",
        "169.254.",
        "[::ffff:",
        # 172.16.0.0 – 172.31.255.255
        "172.16.",
        "172.17.",
        "172.18.",
        "172.19.",
        "172.20.",
        "172.21.",
        "172.22.",
        "172.23.",
        "172.24.",
        "172.25.",
        "172.26.",
        "172.27.",
        "172.28.",
        "172.29.",
        "172.30.",
        "172.31."
      ]) or
      String.contains?(downcased, "::1")
  end

  @doc """
  Extracts the host from a URL string.
  """
  @spec extract_host_from_url(String.t()) :: String.t() | nil
  def extract_host_from_url(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _other -> nil
    end
  end
end
