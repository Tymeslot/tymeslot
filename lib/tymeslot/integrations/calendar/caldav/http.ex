defmodule Tymeslot.Integrations.Calendar.CalDAV.Http do
  @moduledoc """
  CalDAV transport layer.

  Provides credential-aware wrappers for the WebDAV/CalDAV HTTP methods
  (PROPFIND, REPORT, PUT, DELETE, HEAD). Encodes Basic Auth credentials,
  constructs method-specific headers, and maps raw HTTP status codes and
  transport exceptions into the typed `error_reason()` vocabulary.

  This is the only module in the CalDAV stack that communicates with the HTTP
  client. All modules above it work with domain types, not `Req.Response`.
  """

  alias Tymeslot.Infrastructure.RetryLogic
  # Aliased as CalDAVBase to avoid shadowing Elixir's built-in Base module,
  # which is referenced by name in build_headers/3 for Base64 encoding.
  alias Tymeslot.Integrations.Calendar.CalDAV.Base, as: CalDAVBase
  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler

  require Logger

  @doc """
  Performs a PROPFIND request with configurable retry logic.

  Defaults to 2 retries for discovery operations. Pass `max_retries: 0` to
  disable. The `:body` option overrides the default propfind XML payload;
  `:depth` sets the WebDAV Depth header (default `"1"`).
  """
  @spec propfind(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  def propfind(url, username, password, opts \\ []) do
    retry_opts =
      CalDAVBase.default_retry_opts()
      |> Keyword.merge(max_retries: Keyword.get(opts, :max_retries, 2))
      |> Keyword.merge(Keyword.get(opts, :retry_opts, []))

    RetryLogic.with_retry(
      fn -> do_propfind(url, username, password, opts) end,
      retry_opts
    )
  end

  @doc """
  Performs a PROPFIND request to fetch the CTag property for a calendar.
  """
  @spec propfind_ctag(String.t(), String.t(), String.t()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  def propfind_ctag(calendar_url, username, password) do
    body = XmlHandler.build_propfind_request(properties: [:getctag])
    propfind(calendar_url, username, password, body: body, depth: "0")
  end

  defp do_propfind(url, username, password, opts) do
    headers = build_propfind_headers(username, password, opts)
    body = Keyword.get(opts, :body, XmlHandler.build_propfind_request())
    timeout = Keyword.get(opts, :timeout, Keyword.get(opts, :discovery_timeout, 10_000))

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
  defp handle_propfind_error(%Mint.HTTPError{reason: :timeout}), do: {:error, :timeout}

  defp handle_propfind_error(reason) do
    Logger.debug("CalDAV PROPFIND network error", reason: inspect(reason))
    {:error, :network_error}
  end

  @doc """
  Performs a REPORT request for fetching calendar data (e.g., calendar-query).

  No retry logic at this level — callers that need retry wrap this function
  themselves (see `Events.fetch_events/5`).
  """
  @spec report(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  def report(url, username, password, body, opts \\ []) do
    headers =
      build_headers(username, password, [
        {"Content-Type", "application/xml; charset=utf-8"},
        {"Depth", "1"}
      ])

    timeout = Keyword.get(opts, :timeout, CalDAVBase.report_timeout_ms())

    case http_client().request(:report, url, body, headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: 207} = response} ->
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
        Logger.debug("CalDAV REPORT network error", reason: inspect(reason))
        {:error, :network_error}
    end
  end

  @doc """
  Performs a PUT request to create or update a calendar event.

  Pass `operation: :create` to add `If-None-Match: *` preventing accidental
  overwrites. Pass `operation: :update` to add `If-Match: *` or
  `If-Match: <etag>` for conditional writes that prevent lost updates on
  concurrent edits.
  """
  @spec put_event(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  def put_event(url, username, password, ical_data, opts \\ []) do
    headers = build_put_event_headers(username, password, opts)
    # 45s is the sweet spot for CalDAV writes: long enough that transient
    # slowness (backup running, GC pause, lock contention) completes cleanly
    # without interrupting the server mid-write, short enough that a truly
    # dead server is caught well inside the circuit breaker's 70s GenServer
    # budget. Interrupting a CalDAV write mid-flight is the main way a
    # healthy server (Radicale especially) gets wedged — orphan fcntl locks.
    # Oban workers are async, so the user never waits on this timeout.
    timeout = Keyword.get(opts, :timeout, 45_000)

    case http_client().put(url, ical_data, headers, receive_timeout: timeout) do
      {:ok, response} ->
        handle_put_event_response(response)

      {:error, reason} ->
        handle_write_network_error(reason)
    end
  end

  @doc """
  Performs a DELETE request to remove a calendar event.

  A 404 response is treated as success — deletes are idempotent.
  """
  @spec delete_event(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  def delete_event(url, username, password, opts \\ []) do
    headers = build_headers(username, password, [])
    # Matches put_event — see the note there for rationale.
    timeout = Keyword.get(opts, :timeout, 45_000)

    case http_client().delete(url, headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status} = response} when status in [200, 204, 404] ->
        # 404 is ok for delete — event may already be gone
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
        handle_write_network_error(reason)
    end
  end

  @doc """
  Performs a HEAD request to retrieve current headers (e.g., ETag) for an event.
  """
  @spec head_event(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  def head_event(url, username, password, opts \\ []) do
    headers = build_headers(username, password, [])
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

  # Private helpers

  defp build_headers(username, password, additional_headers)
       when is_binary(username) and is_binary(password) do
    # Base.encode64 here refers to Elixir's standard Base module, not
    # Tymeslot.Integrations.Calendar.CalDAV.Base (which is aliased as CalDAVBase).
    auth_header = {"Authorization", "Basic " <> Base.encode64("#{username}:#{password}")}
    [auth_header | additional_headers]
  end

  defp build_headers(_username, _password, _additional_headers) do
    raise ArgumentError, "CalDAV credentials must be non-nil binaries"
  end

  defp build_put_event_headers(username, password, opts) do
    base_headers =
      build_headers(username, password, [{"Content-Type", "text/calendar; charset=utf-8"}])

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
       when status in [200, 201, 204],
       do: {:ok, response}

  defp handle_put_event_response(%Req.Response{status: 401}), do: {:error, :unauthorized}
  defp handle_put_event_response(%Req.Response{status: 403}), do: {:error, :unauthorized}
  defp handle_put_event_response(%Req.Response{status: 404}), do: {:error, :not_found}

  defp handle_put_event_response(%Req.Response{status: 412}),
    do: {:error, :precondition_failed}

  defp handle_put_event_response(%Req.Response{status: status}) when status >= 500,
    do: {:error, :server_error}

  defp handle_put_event_response(%Req.Response{status: status}),
    do: {:error, "Unexpected status: #{status}"}

  defp handle_write_network_error(%Mint.TransportError{reason: :timeout}),
    do: write_timeout_error()

  defp handle_write_network_error(%Req.TransportError{reason: :timeout}),
    do: write_timeout_error()

  defp handle_write_network_error(%Mint.HTTPError{reason: :timeout}),
    do: write_timeout_error()

  defp handle_write_network_error(reason) do
    Logger.debug("CalDAV PUT/DELETE network error", reason: inspect(reason))
    {:error, :network_error}
  end

  defp write_timeout_error do
    Logger.warning(
      "CalDAV server did not respond within the write timeout. The server is " <>
        "likely stuck, overloaded, or blocked on a stale lock — check the " <>
        "server's logs and restart it if the condition persists."
    )

    {:error, :server_unresponsive}
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
  end
end
