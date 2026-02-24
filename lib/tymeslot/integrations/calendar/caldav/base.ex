defmodule Tymeslot.Integrations.Calendar.CalDAV.Base do
  @moduledoc """
  Base module for CalDAV-compatible calendar providers.

  This module provides shared functionality for all CalDAV-based providers
  including generic CalDAV, Nextcloud, Radicale, and other CalDAV servers.

  ## Features
  - Common HTTP operations (PROPFIND, REPORT, PUT, DELETE)
  - Basic authentication handling
  - Calendar discovery
  - Event CRUD operations
  - Error normalization

  ## Timeout Hierarchy

  Timeouts are configured in a hierarchy to ensure inner operations time out
  before outer ones, providing cleaner error propagation:

      report_timeout (10s) < task_await_timeout (25s) < coalescer_call_timeout (30s)

  With retry logic (max 1 retry, 500ms base delay):
  - Worst case single operation: ~21s (10s + 0.5s delay + 10s retry)
  - This fits within the task_await_timeout (25s)
  - The coalescer_call_timeout (30s) provides buffer for GenServer overhead

  ## Retry Strategy

  Retry logic is applied at specific layers to avoid double-retrying:

  | Function            | Has Retry? | Wrapped By         | Notes                        |
  |---------------------|------------|--------------------|-----------------------------|
  | `propfind/4`        | ✓          | -                  | 2 retries for discovery      |
  | `report/5`          | ✗          | `fetch_events/5`   | Low-level, no retry          |
  | `fetch_events/5`    | ✓          | -                  | 1 retry, wraps report/5      |
  | `put_event/5`       | ✗          | -                  | No retry (write operation)   |
  | `delete_event/4`    | ✗          | -                  | No retry (write operation)   |

  Retryable errors: `:network_error`, `:timeout`, `:server_error`
  """

  alias Tymeslot.Infrastructure.{CalendarCircuitBreaker, RetryLogic}
  alias Tymeslot.Integrations.Calendar.CalDAV.{UrlBuilder, XmlHandler}
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Security.{CredentialManager, RateLimiter}

  require Logger

  # Timeout configuration for CalDAV operations
  # Hierarchy: report_timeout < task_await_timeout < coalescer_call_timeout
  # With retry: worst case = report_timeout + base_delay + report_timeout ≈ 21s
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

  # Expose timeouts for other modules to reference
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
          | {:error, String.t()}

  @doc """
  Performs a PROPFIND request for calendar discovery with retry logic.
  """
  @spec propfind(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  def propfind(url, username, password, opts \\ []) do
    retry_opts =
      @default_retry_opts
      |> Keyword.merge(max_retries: Keyword.get(opts, :max_retries, 2))
      |> Keyword.merge(Keyword.get(opts, :retry_opts, []))

    RetryLogic.with_retry(
      fn ->
        do_propfind(url, username, password, opts)
      end,
      retry_opts
    )
  end

  defp do_propfind(url, username, password, opts) do
    headers = build_propfind_headers(username, password, opts)
    body = Keyword.get(opts, :body, XmlHandler.build_propfind_request())
    timeout = get_propfind_timeout(opts)

    case http_client().request(:propfind, url, body, headers, receive_timeout: timeout) do
      {:ok, response} -> handle_propfind_response(response)
      {:error, reason} -> handle_propfind_error(reason)
    end
  end

  defp build_propfind_headers(username, password, opts) do
    build_headers(username, password, [
      {"Content-Type", "application/xml"},
      {"Depth", Keyword.get(opts, :depth, "1")}
    ])
  end

  defp get_propfind_timeout(opts) do
    Keyword.get(opts, :timeout, Keyword.get(opts, :discovery_timeout, 10_000))
  end

  defp handle_propfind_response(%Req.Response{status: 207} = response), do: {:ok, response}

  defp handle_propfind_response(%Req.Response{status: status} = response)
       when status in 200..299,
       do: {:ok, response}

  defp handle_propfind_response(%Req.Response{status: 401}), do: {:error, :unauthorized}
  defp handle_propfind_response(%Req.Response{status: 403}), do: {:error, :unauthorized}
  defp handle_propfind_response(%Req.Response{status: 404}), do: {:error, :not_found}

  defp handle_propfind_response(%Req.Response{status: status}) when status >= 500,
    do: {:error, :server_error}

  defp handle_propfind_response(%Req.Response{status: status}),
    do: {:error, "Unexpected status: #{status}"}

  defp handle_propfind_error(%Mint.TransportError{reason: :timeout}), do: {:error, :timeout}
  defp handle_propfind_error(%Req.TransportError{reason: :timeout}), do: {:error, :timeout}

  defp handle_propfind_error(reason) do
    Logger.debug("CalDAV PROPFIND network error: #{inspect(reason)}")
    {:error, :network_error}
  end

  @doc """
  Performs a REPORT request for fetching events.
  """
  @spec report(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  def report(url, username, password, body, opts \\ []) do
    headers =
      build_headers(username, password, [
        {"Content-Type", "application/xml; charset=utf-8"},
        {"Depth", "1"}
      ])

    timeout = Keyword.get(opts, :timeout, @report_timeout_ms)

    case http_client().request(:report, url, body, headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: 207} = response} ->
        # 207 Multi-Status is the expected response for REPORT
        {:ok, response}

      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 403}} ->
        # Radicale returns 403 for auth failures
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, :server_error}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Unexpected status: #{status}"}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Mint.HTTPError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        Logger.debug("CalDAV REPORT network error: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  @doc """
  Performs a PUT request to create or update an event.
  """
  @spec put_event(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  def put_event(url, username, password, ical_data, opts \\ []) do
    headers = build_put_event_headers(username, password, opts)
    # Increased default timeout to 60s for background operations (was 10s)
    # Background workers have 90s timeout, so 60s gives buffer for slow CalDAV servers
    timeout = Keyword.get(opts, :timeout, 60_000)

    case http_client().put(url, ical_data, headers, receive_timeout: timeout) do
      {:ok, response} ->
        handle_put_event_response(response)

      {:error, reason} ->
        Logger.debug("CalDAV PUT network error: #{inspect(reason)}")
        {:error, :network_error}
    end
  end

  @doc """
  Performs a DELETE request to remove an event.
  """
  @spec delete_event(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  def delete_event(url, username, password, opts \\ []) do
    headers = build_headers(username, password, [])
    # Increased default timeout to 60s for background operations (was 10s)
    timeout = Keyword.get(opts, :timeout, 60_000)

    case http_client().delete(url, headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status} = response} when status in [200, 204, 404] ->
        # 404 is ok for delete - event may already be gone
        {:ok, response}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 403}} ->
        # Radicale returns 403 for auth failures
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, :server_error}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Unexpected status: #{status}"}

      {:error, reason} ->
        handle_put_event_error(reason)
    end
  end

  defp build_put_event_headers(username, password, opts) do
    base_headers =
      build_headers(username, password, [
        {"Content-Type", "text/calendar; charset=utf-8"}
      ])

    add_conditional_headers(base_headers, opts)
  end

  defp add_conditional_headers(headers, opts) do
    case Keyword.get(opts, :operation) do
      :update ->
        case Keyword.get(opts, :if_match) do
          nil -> headers ++ [{"If-Match", "*"}]
          etag -> headers ++ [{"If-Match", etag}]
        end

      :create ->
        headers ++ [{"If-None-Match", "*"}]

      _operation ->
        headers
    end
  end

  defp handle_put_event_response(%Req.Response{status: status} = response)
       when status in [200, 201, 204] do
    {:ok, response}
  end

  defp handle_put_event_response(%Req.Response{status: 401}), do: {:error, :unauthorized}
  defp handle_put_event_response(%Req.Response{status: 403}), do: {:error, :unauthorized}
  defp handle_put_event_response(%Req.Response{status: 404}), do: {:error, :not_found}

  defp handle_put_event_response(%Req.Response{status: 412}) do
    {:error, "Precondition failed - event may already exist"}
  end

  defp handle_put_event_response(%Req.Response{status: status}) when status >= 500 do
    {:error, :server_error}
  end

  defp handle_put_event_response(%Req.Response{status: status}) do
    {:error, "Unexpected status: #{status}"}
  end

  defp handle_put_event_error(reason) do
    Logger.debug("CalDAV PUT/DELETE network error: #{inspect(reason)}")
    {:error, :network_error}
  end

  @doc """
  Tests connection to a CalDAV server.
  """
  @spec test_connection(client(), keyword()) :: {:ok, String.t()} | {:error, error_reason()}
  def test_connection(client, opts \\ []) do
    # Rate limit check
    ip_address = Keyword.get(opts, :ip_address, "127.0.0.1")

    with :ok <- check_rate_limit(:connection, ip_address),
         {:ok, secure_client} <- CredentialManager.encrypt_client_credentials(client) do
      # Try to discover calendars as a connection test
      discovery_url = UrlBuilder.build_discovery_url(client)

      # Use decrypted credentials only for the HTTP call
      result =
        CredentialManager.with_decrypted_credentials(secure_client, fn decrypted ->
          case propfind(discovery_url, decrypted.username, decrypted.password,
                 depth: "0",
                 max_retries: 0
               ) do
            {:ok, _response} = result ->
              result

            {:error, reason} when reason in [:not_found, :server_error] ->
              # The guessed discovery path does not exist on this server.
              # Fall back to RFC 4791: PROPFIND server root for current-user-principal.
              # This handles servers like Zimbra where the generic /calendars/{user}/ path
              # is wrong but the credentials themselves are valid.
              Logger.debug(
                "CalDAV discovery path not found (#{reason}), falling back to RFC 4791 probe",
                base_url: client.base_url
              )

              rfc4791_probe(client.base_url, decrypted.username, decrypted.password)

            {:error, _reason} = result ->
              result
          end
        end)

      case result do
        {:ok, %Req.Response{status: 207}} ->
          {:ok, "CalDAV connection successful"}

        {:ok, %Req.Response{}} ->
          {:ok, "CalDAV connection successful"}

        {:error, :unauthorized} ->
          {:error, :unauthorized}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Discovers available calendars on the CalDAV server with circuit breaker protection.
  """
  @spec discover_calendars(client(), keyword()) :: {:ok, list(map())} | {:error, error_reason()}
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
            # current-user-principal → calendar-home-set → calendar list.
            Logger.debug(
              "CalDAV discovery path not found (#{reason}), falling back to RFC 4791 principal discovery",
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
  Fetches events from a calendar within a time range.
  """
  @spec fetch_events(client(), String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, list(map())} | {:error, error_reason()}
  def fetch_events(client, calendar_path, start_time, end_time, opts \\ []) do
    with_caldav_breaker(client, opts, fn ->
      url = UrlBuilder.build_calendar_url(client.base_url, calendar_path)

      # Build calendar-query XML
      report_body = XmlHandler.build_calendar_query(start_time, end_time)

      retry_opts = Keyword.get(opts, :retry_opts, @default_retry_opts)
      report_timeout = Keyword.get(opts, :timeout, @report_timeout_ms)

      report_opts = Keyword.put(opts, :timeout, report_timeout)

      case RetryLogic.with_retry(
             fn -> report(url, client.username, client.password, report_body, report_opts) end,
             retry_opts
           ) do
        {:ok, %Req.Response{status: 207, body: body}} ->
          parse_events_response(body)

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          # Non-standard: CalDAV REPORT should return 207 Multi-Status
          # Some servers may return 200 OK - accept it but log for debugging
          Logger.warning("CalDAV REPORT returned #{status} instead of 207 Multi-Status",
            url: url,
            provider: Map.get(client, :provider, :caldav)
          )

          parse_events_response(body)

        {:error, reason} ->
          {:error, reason}
      end
    end)
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

  @doc """
  Performs a HEAD request to fetch current headers (e.g., ETag) for an event resource.
  """
  @spec head_event(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, error_reason()}
  def head_event(url, username, password, opts \\ []) do
    headers = build_headers(username, password, [])
    # Increased default timeout to 30s for consistency with REPORT operations
    timeout = Keyword.get(opts, :timeout, 30_000)

    case http_client().head(url, headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status} = response} when status in [200, 204] ->
        {:ok, response}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, :server_error}

      {:error, _error_reason} ->
        {:error, :network_error}
    end
  end

  # Private helper functions

  defp build_headers(username, password, additional_headers) do
    auth_header = {"Authorization", "Basic " <> Base.encode64("#{username}:#{password}")}
    [auth_header | additional_headers]
  end

  # RFC 4791 discovery helpers

  # Probes the server root with a current-user-principal PROPFIND to verify
  # that credentials are valid when the guessed discovery path fails.
  # A 207 response here proves the credentials work even if the path was wrong.
  defp rfc4791_probe(base_url, username, password) do
    url = UrlBuilder.build_calendar_url(base_url, "/")
    body = XmlHandler.build_propfind_request(properties: [:current_user_principal])
    propfind(url, username, password, body: body, depth: "0")
  end

  # Full RFC 4791 discovery chain:
  #   1. PROPFIND server root → current-user-principal href
  #   2. PROPFIND principal URL → calendar-home-set href
  #   3. PROPFIND calendar-home-set → list of calendars
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

  defp parse_events_response(xml_body) do
    XmlHandler.parse_calendar_query(xml_body)
  end

  defp build_ical_data(event_data, uid) do
    ICalBuilder.build_simple_event(uid, event_data)
  end

  defp generate_uid do
    ICalBuilder.generate_uid()
  end

  defp check_rate_limit(:connection, ip_address) do
    case RateLimiter.check_caldav_connection_rate_limit(ip_address) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, message}
    end
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
    host == "localhost" or
      String.starts_with?(host, [
        "127.",
        "10.",
        "192.168.",
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
      ])
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
  end

  defp extract_host_from_url(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _other -> nil
    end
  end
end
