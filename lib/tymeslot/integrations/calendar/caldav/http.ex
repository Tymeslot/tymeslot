defmodule Tymeslot.Integrations.Calendar.CalDAV.Http do
  @moduledoc """
  CalDAV transport layer.

  Provides credential-aware wrappers for the WebDAV/CalDAV HTTP methods
  (PROPFIND, REPORT, PUT, DELETE, HEAD). Encodes Basic Auth credentials,
  constructs method-specific headers, and maps raw HTTP status codes and
  transport exceptions into the typed `error_reason()` vocabulary.

  Every method maps statuses through one shared classifier (`classify/4`), so a
  status can only mean one thing across the stack. A method declares which
  statuses count as success and, via `:status_overrides`, the few whose meaning
  is genuinely its own: a DELETE is idempotent so 404 succeeds, a
  sync-collection REPORT answers 410 when its token has expired.

  This is the only module in the CalDAV stack that communicates with the HTTP
  client. All modules above it work with domain types, not `Req.Response`.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.RetryLogic
  # Aliased as CalDAVBase to avoid shadowing Elixir's built-in Base module,
  # which is referenced by name in build_headers/3 for Base64 encoding.
  alias Tymeslot.Integrations.Calendar.CalDAV.Base, as: CalDAVBase
  alias Tymeslot.Integrations.Calendar.CalDAV.DigestAuth
  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler
  alias Tymeslot.Integrations.Calendar.Shared.HttpLogging

  require Logger

  # Statuses whose meaning is the same whichever CalDAV method produced them.
  # Anything absent is either declared a success by the calling method, given a
  # method-specific meaning via `:status_overrides`, or falls through to
  # `unexpected_status/3`.
  @status_reasons %{
    401 => :unauthorized,
    403 => :forbidden,
    404 => :not_found,
    # The URL exists but does not speak this method: a PROPFIND at a path that
    # is not DAV-mounted, or a reverse proxy answering unknown methods itself.
    # Deliberately *not* folded into `:not_found`, which is a destructive
    # sentinel elsewhere (it deletes calendar paths and local rows).
    405 => :method_not_allowed,
    408 => :timeout,
    429 => :rate_limited
  }

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
    body = Keyword.get(opts, :body, XmlHandler.build_propfind_request())
    timeout = Keyword.get(opts, :timeout, Keyword.get(opts, :discovery_timeout, 10_000))

    extra_headers = [
      {"Content-Type", "application/xml"},
      {"Depth", Keyword.get(opts, :depth, "1")}
    ]

    result =
      authed_request("PROPFIND", url, username, password, extra_headers, fn headers ->
        Config.http_client_module().request(:propfind, url, body, headers,
          receive_timeout: timeout,
          ssrf_protect: true
        )
      end)

    case result do
      {:ok, response} -> classify(response, :propfind, url, success: 200..299)
      {:error, reason} -> handle_read_transport_error(reason, "PROPFIND")
    end
  end

  @doc """
  Performs a REPORT request for fetching calendar data (e.g., calendar-query).

  No retry logic at this level — callers that need retry wrap this function
  themselves (see `Events.fetch_events/5`).

  Options:

    * `:depth` — the WebDAV Depth header, default `"1"`. A sync-collection
      REPORT must pass `"0"`; see RFC 6578, Section 3.2.
    * `:status_overrides` — a `%{status => reason}` map applied before the
      shared table, for statuses that mean something specific to the report
      being sent (410 as an expired sync token, say).
  """
  @spec report(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  def report(url, username, password, body, opts \\ []) do
    extra_headers = [
      {"Content-Type", "application/xml; charset=utf-8"},
      {"Depth", Keyword.get(opts, :depth, "1")}
    ]

    timeout = Keyword.get(opts, :timeout, CalDAVBase.report_timeout_ms())

    result =
      authed_request("REPORT", url, username, password, extra_headers, fn headers ->
        Config.http_client_module().request(:report, url, body, headers,
          receive_timeout: timeout,
          ssrf_protect: true
        )
      end)

    case result do
      {:ok, response} ->
        classify(response, :report, url,
          success: 200..299,
          status_overrides: Keyword.get(opts, :status_overrides, %{})
        )

      {:error, reason} ->
        handle_read_transport_error(reason, "REPORT")
    end
  end

  @doc """
  Performs a PUT request to create or update a calendar event.

  Pass `operation: :create` to add `If-None-Match: *` preventing accidental
  overwrites. Pass `operation: :update` to add `If-Match: *` or
  `If-Match: <etag>` for conditional writes that prevent lost updates on
  concurrent edits. Pass `operation: :force_update` to send no conditional
  header at all — an unconditional overwrite.
  """
  @spec put_event(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  def put_event(url, username, password, ical_data, opts \\ []) do
    extra_headers = put_event_headers(opts)
    # 45s is the sweet spot for CalDAV writes: long enough that transient
    # slowness (backup running, GC pause, lock contention) completes cleanly
    # without interrupting the server mid-write, short enough that a truly
    # dead server is caught well inside the circuit breaker's 70s GenServer
    # budget. Interrupting a CalDAV write mid-flight is the main way a
    # healthy server (Radicale especially) gets wedged — orphan fcntl locks.
    # Oban workers are async, so the user never waits on this timeout.
    timeout = Keyword.get(opts, :timeout, 45_000)

    result =
      authed_request("PUT", url, username, password, extra_headers, fn headers ->
        Config.http_client_module().put(url, ical_data, headers,
          receive_timeout: timeout,
          ssrf_protect: true
        )
      end)

    case result do
      {:ok, response} ->
        classify(response, :put, url,
          success: [200, 201, 204],
          # RFC 7232 reserves 412 for a failed precondition, but some CalDAV
          # servers answer a conditional PUT with 409 instead — including
          # servers that reject the conditional form outright rather than
          # evaluating it. Kept distinct from :precondition_failed so the
          # caller can tell "the condition did not hold" from "this server
          # will not honour the condition".
          status_overrides: %{409 => :conditional_not_supported, 412 => :precondition_failed}
        )

      {:error, reason} ->
        handle_write_transport_error(reason)
    end
  end

  @doc """
  Performs a DELETE request to remove a calendar event.

  A 404 response is treated as success — deletes are idempotent.
  """
  @spec delete_event(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  def delete_event(url, username, password, opts \\ []) do
    # Matches put_event — see the note there for rationale.
    timeout = Keyword.get(opts, :timeout, 45_000)

    result =
      authed_request("DELETE", url, username, password, [], fn headers ->
        Config.http_client_module().delete(url, headers,
          receive_timeout: timeout,
          ssrf_protect: true
        )
      end)

    case result do
      {:ok, response} ->
        # 404 counts as success — the event may already be gone.
        classify(response, :delete, url, success: [200, 204, 404])

      {:error, reason} ->
        handle_write_transport_error(reason)
    end
  end

  @doc """
  Performs a HEAD request to retrieve current headers (e.g., ETag) for an event.
  """
  @spec head_event(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  def head_event(url, username, password, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    result =
      authed_request("HEAD", url, username, password, [], fn headers ->
        Config.http_client_module().head(url, headers,
          receive_timeout: timeout,
          ssrf_protect: true
        )
      end)

    case result do
      {:ok, response} -> classify(response, :head, url, success: [200, 204])
      {:error, _error_reason} -> {:error, :network_error}
    end
  end

  # Private helpers

  # One status vocabulary for every CalDAV method. `:success` declares the
  # statuses this method treats as a result, `:status_overrides` the few whose
  # meaning is method-specific; everything else resolves through the shared
  # table so no method can quietly grow its own dialect.
  @spec classify(Req.Response.t(), atom(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, CalDAVBase.error_reason()}
  defp classify(%Req.Response{status: status} = response, method, url, opts) do
    overrides = Keyword.get(opts, :status_overrides, %{})

    cond do
      status in Keyword.fetch!(opts, :success) -> {:ok, response}
      is_map_key(overrides, status) -> {:error, Map.fetch!(overrides, status)}
      is_map_key(@status_reasons, status) -> {:error, Map.fetch!(@status_reasons, status)}
      status >= 500 -> {:error, :server_error}
      true -> {:error, unexpected_status(response, method, url)}
    end
  end

  # The server's own explanation is the only thing that makes an unmodelled
  # status diagnosable: a bare 415 covers a dozen causes, and the body says
  # which one. Without the excerpt the failure reaches the operator as a status
  # code and nothing else.
  defp unexpected_status(%Req.Response{status: status, body: body}, method, url) do
    Logger.warning("CalDAV request returned an unhandled status",
      method: method,
      url: HttpLogging.loggable_url(url, include_path: true),
      status: status,
      body: HttpLogging.body_excerpt(body)
    )

    {:unexpected_status, status}
  end

  # Every CalDAV request goes out with Basic credentials. A server that answers
  # 401 with a Digest challenge gets exactly one retry carrying the computed
  # Digest response, and the caller sees only the second answer.
  #
  # This is not a niche path: Baikal ships `dav_auth_type: Digest` as its
  # default and SabreDAV refuses a Basic header outright in that mode, so
  # without this a stock Baikal install is unreachable however correct the
  # credentials are. See `CalDAV.DigestAuth` for what the challenge may name.
  #
  # `http_method` is the uppercase method as it goes on the wire; it is hashed
  # into the digest credentials, so it must match the request `send` performs.
  @spec authed_request(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          list(),
          (list() -> result)
        ) :: result
        when result: {:ok, Req.Response.t()} | {:error, Exception.t()}
  defp authed_request(http_method, url, username, password, extra_headers, send) do
    case send.(build_headers(username, password, extra_headers)) do
      {:ok, %Req.Response{status: 401} = response} ->
        retry_with_digest(response, http_method, url, username, password, extra_headers, send)

      result ->
        result
    end
  end

  defp retry_with_digest(response, http_method, url, username, password, extra_headers, send) do
    case DigestAuth.build_authorization(response, http_method, url, username, password) do
      {:ok, authorization} ->
        send.([authorization | extra_headers])

      # No Digest challenge at all: an ordinary rejected-credentials 401 from a
      # Basic-auth server. The original response carries the right meaning.
      :none ->
        {:ok, response}

      # The server does want Digest, but named something this client cannot
      # compute. The account owner will see the generic credentials message, so
      # the specific cause has to reach the operator here or nowhere.
      {:unsupported, detail} ->
        Logger.warning(
          "CalDAV server requires a Digest challenge Tymeslot cannot answer",
          method: http_method,
          url: HttpLogging.loggable_url(url, include_path: true),
          detail: detail
        )

        {:ok, response}
    end
  end

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

  defp put_event_headers(opts) do
    add_conditional_headers([{"Content-Type", "text/calendar; charset=utf-8"}], opts)
  end

  defp add_conditional_headers(headers, opts) do
    case Keyword.get(opts, :operation) do
      :update ->
        case Keyword.get(opts, :if_match) do
          nil -> headers ++ [{"If-Match", "*"}]
          etag -> headers ++ [{"If-Match", etag}]
        end

      # Unconditional overwrite: no If-Match at all. Used by the :keep_local
      # conflict policy, whose contract is "force the local version through",
      # and as the fallback when a server rejects the conditional form itself.
      :force_update ->
        headers

      :create ->
        headers ++ [{"If-None-Match", "*"}]

      _operation ->
        headers
    end
  end

  defp handle_read_transport_error(%Mint.TransportError{reason: :timeout}, _method),
    do: {:error, :timeout}

  defp handle_read_transport_error(%Req.TransportError{reason: :timeout}, _method),
    do: {:error, :timeout}

  defp handle_read_transport_error(%Mint.HTTPError{reason: :timeout}, _method),
    do: {:error, :timeout}

  defp handle_read_transport_error(reason, method) do
    Logger.debug("CalDAV read network error", method: method, reason: inspect(reason))
    {:error, :network_error}
  end

  defp handle_write_transport_error(%Mint.TransportError{reason: :timeout}),
    do: write_timeout_error()

  defp handle_write_transport_error(%Req.TransportError{reason: :timeout}),
    do: write_timeout_error()

  defp handle_write_transport_error(%Mint.HTTPError{reason: :timeout}),
    do: write_timeout_error()

  defp handle_write_transport_error(reason) do
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
end
