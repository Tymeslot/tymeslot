defmodule Tymeslot.Infrastructure.ResponseTooLargeError do
  @moduledoc """
  Returned by `Tymeslot.Infrastructure.HTTPClient` when a response body exceeds
  the request's byte budget. The transfer is aborted at the chunk that crosses
  the budget, so the oversized body is never fully held in memory.
  """

  alias Tymeslot.Infrastructure.HTTPClient

  defexception [:url, :max_bytes]

  @impl Exception
  def message(%__MODULE__{url: url, max_bytes: max_bytes}) do
    origin = HTTPClient.log_safe_origin(url)
    "response from #{origin} exceeded the #{max_bytes} byte limit"
  end
end

defmodule Tymeslot.Infrastructure.HTTPClient do
  @moduledoc """
  Standardized HTTP client for the application.
  Wraps Req and provides consistent interface for all HTTP requests.

  Every response body is streamed through a byte budget (`:max_response_bytes`,
  defaulting to `config :tymeslot, :http_max_response_bytes`) and the transfer is
  aborted as soon as it is exceeded, so no single remote server can exhaust the
  node's memory with an unbounded body. Requests supplying their own `:into`
  option own their body handling and are left alone.
  """

  @behaviour Tymeslot.Infrastructure.HTTPClientBehaviour

  require Logger
  alias Req.{Request, Response}
  alias Tymeslot.Infrastructure.{Metrics, ProxyConfig, ResponseTooLargeError}
  alias Tymeslot.Security.{SsrfBlockedError, SsrfGuard}

  # Generous enough that no legitimate response comes close: the largest bodies
  # the app handles are a full CalDAV REPORT and a 2,500-event Google page, both
  # single-digit megabytes.
  @max_response_bytes Application.compile_env(
                        :tymeslot,
                        :http_max_response_bytes,
                        50 * 1024 * 1024
                      )

  @operation_timeouts %{
    # Read operations get standard timeout
    get: 30_000,
    head: 30_000,
    options: 30_000,

    # Write operations get longer timeout
    post: 45_000,
    put: 45_000,
    delete: 45_000,
    patch: 45_000,

    # CalDAV operations can be slow with large calendars
    report: 60_000,
    propfind: 60_000
  }

  @doc """
  Reduces a URL to `scheme://host` for logging: never the path or query,
  since some destinations (the Telegram Bot API) carry their credential in
  the URL path. Falls back to `"unknown"` for a URL with no scheme/host
  (relative or malformed) rather than logging a bare `"://"`.
  """
  @spec log_safe_origin(String.t()) :: String.t()
  def log_safe_origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}"

      _other ->
        "unknown"
    end
  end

  @doc """
  Performs a GET request.
  """
  @spec get(String.t(), list(), keyword()) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  def get(url, headers \\ [], options \\ []) do
    request(:get, url, "", headers, options)
  end

  @doc """
  Performs a POST request.
  """
  @spec post(String.t(), any(), list(), keyword()) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  def post(url, body, headers \\ [], options \\ []) do
    request(:post, url, body, headers, options)
  end

  @doc """
  Performs a PUT request.
  """
  @spec put(String.t(), any(), list(), keyword()) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  def put(url, body, headers \\ [], options \\ []) do
    request(:put, url, body, headers, options)
  end

  @doc """
  Performs a DELETE request.
  """
  @spec delete(String.t(), list(), keyword()) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  def delete(url, headers \\ [], options \\ []) do
    request(:delete, url, "", headers, options)
  end

  @doc """
  Performs a HEAD request.
  """
  @spec head(String.t(), list(), keyword()) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  def head(url, headers \\ [], options \\ []) do
    request(:head, url, "", headers, options)
  end

  @doc """
  Performs a REPORT request (CalDAV specific).
  """
  @spec report(String.t(), any(), list(), keyword()) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  def report(url, body, headers \\ [], options \\ []) do
    request(:report, url, body, headers, options)
  end

  @allowed_methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete,
    "head" => :head,
    "options" => :options,
    "report" => :report,
    "propfind" => :propfind
  }

  @doc """
  Performs any HTTP method request.
  Supports both atom and string method names.
  """
  @spec request(atom() | String.t(), String.t(), any(), list(), keyword()) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  def request(method, url, body \\ "", headers \\ [], options \\ [])

  def request(method, url, body, headers, options) when is_atom(method) do
    if Keyword.get(options, :ssrf_protect, false) do
      guarded_request(method, url, body, headers, options)
    else
      do_request(method, url, body, headers, options)
    end
  end

  def request(method, url, body, headers, options) when is_binary(method) do
    downcased = String.downcase(method)

    case Map.fetch(@allowed_methods, downcased) do
      {:ok, atom_method} ->
        request(atom_method, url, body, headers, options)

      :error ->
        {:error, %RuntimeError{message: "Invalid HTTP method: #{method}"}}
    end
  end

  def request(method, _url, _body, _headers, _options) do
    {:error, %RuntimeError{message: "Invalid HTTP method: #{inspect(method)}"}}
  end

  # Private functions

  @spec do_request(atom(), String.t(), any(), list(), keyword()) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  defp do_request(method, url, body, headers, options) do
    req_options = build_req_options(method, url, body, headers, options)

    result =
      track_request(method, url, fn ->
        Req.request(req_options)
      end)

    # Metrics are recorded first so an oversized response still reports the
    # status and duration the server actually produced.
    if Keyword.has_key?(options, :into) do
      result
    else
      finish_capped_body(result, url, max_response_bytes(options))
    end
  end

  @spec max_response_bytes(keyword()) :: pos_integer()
  defp max_response_bytes(options) do
    Keyword.get(options, :max_response_bytes, @max_response_bytes)
  end

  # `capped_collector/1` accumulates chunks as iodata and flags the response
  # once the budget is crossed; this turns that back into the plain binary body
  # every caller expects, or into an error when the transfer was aborted.
  @spec finish_capped_body(
          {:ok, Response.t()} | {:error, Exception.t()},
          String.t(),
          pos_integer()
        ) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  defp finish_capped_body({:ok, %Response{} = response}, url, max_bytes) do
    if Response.get_private(response, :tymeslot_body_too_large, false) do
      Logger.warning("Aborted an oversized HTTP response",
        url: log_safe_origin(url),
        status_code: response.status,
        max_response_bytes: max_bytes
      )

      {:error, %ResponseTooLargeError{url: url, max_bytes: max_bytes}}
    else
      {:ok, %{response | body: IO.iodata_to_binary(response.body)}}
    end
  end

  defp finish_capped_body(result, _url, _max_bytes), do: result

  @spec capped_collector(pos_integer()) ::
          ({:data, binary()}, {Request.t(), Response.t()} ->
             {:cont | :halt, {Request.t(), Response.t()}})
  defp capped_collector(max_bytes) do
    fn {:data, chunk}, {request, response} ->
      received =
        Response.get_private(response, :tymeslot_received_bytes, 0) + byte_size(chunk)

      if received > max_bytes do
        {:halt, {request, Response.put_private(response, :tymeslot_body_too_large, true)}}
      else
        response =
          response
          |> Map.update!(:body, &[&1, chunk])
          |> Response.put_private(:tymeslot_received_bytes, received)

        {:cont, {request, response}}
      end
    end
  end

  # Request-time SSRF protection for user-supplied hosts (CalDAV, self-hosted
  # video). Validates that the URL does not resolve to a private/local address
  # *immediately before* connecting (closing the DNS-rebinding gap), and
  # disables Req's automatic redirect following so a 3xx from a public host
  # cannot silently bounce the request onto an internal address.
  @spec guarded_request(atom(), String.t(), any(), list(), keyword()) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  defp guarded_request(method, url, body, headers, options) do
    guard_opts =
      case Keyword.fetch(options, :ssrf_allow_private) do
        {:ok, allow_private} -> [allow_private: allow_private]
        :error -> []
      end

    case SsrfGuard.validate(url, guard_opts) do
      :ok ->
        safe_options =
          options
          |> Keyword.drop([:ssrf_protect, :ssrf_allow_private])
          |> Keyword.put(:redirect, false)

        do_request(method, url, body, headers, safe_options)

      {:error, reason} ->
        Logger.warning("Blocked outbound request by SSRF protection",
          url: log_safe_origin(url),
          reason: inspect(reason)
        )

        {:error, %SsrfBlockedError{url: url, reason: reason}}
    end
  end

  # Standard HTTP methods that Finch accepts as atoms.
  # Non-standard methods (e.g. PROPFIND, REPORT) must be passed as uppercase strings.
  @standard_methods ~w(get post put patch delete head options)a

  @spec build_req_options(atom(), String.t(), any(), list(), keyword()) :: keyword()
  defp build_req_options(method, url, body, headers, user_options) do
    # Get timeout for this operation
    timeout = get_timeout(method, user_options)

    # Get proxy configuration for this URL (considers NO_PROXY, HTTP vs HTTPS)
    proxy_options = get_proxy_options(url)

    req_method = normalize_method(method)

    # Build base request options
    # NOTE: Cannot set both :finch and :connect_options (Req limitation)
    # When proxy is configured, connect_options will be set, so don't set finch
    base_options =
      if proxy_options == [] do
        {transport_key, transport_val} = req_transport_option()

        base = [
          method: req_method,
          url: url,
          headers: headers,
          receive_timeout: timeout,
          # Disable Req's default retry: :safe_transient which silently retries
          # GET/HEAD/OPTIONS on 5xx and transient errors. Retries are handled
          # explicitly at the CalDAV layer (RetryLogic) and Oban layer.
          retry: false,
          # Disable automatic JSON decoding to match HTTPoison behavior
          # Callers handle JSON parsing explicitly with Jason.decode!
          decode_body: false
        ]

        Keyword.put(base, transport_key, transport_val)
      else
        [
          method: req_method,
          url: url,
          headers: headers,
          receive_timeout: timeout,
          retry: false,
          decode_body: false
        ]
      end

    # Add body if present (and not empty)
    options_with_body =
      if body != "" and body != nil do
        Keyword.put(base_options, :body, body)
      else
        base_options
      end

    # Stream the response through the byte budget unless the caller is handling
    # the body itself. Setting `:into` also disables Req's `compressed` and
    # `decompress_body` steps, which is the point: both inflate the whole body
    # into memory with no size limit, so a cap that ran after them would not be
    # a cap at all.
    options_with_cap =
      if Keyword.has_key?(user_options, :into) do
        options_with_body
      else
        Keyword.put(options_with_body, :into, capped_collector(max_response_bytes(user_options)))
      end

    # Add proxy options if configured
    options_with_proxy = Keyword.merge(options_with_cap, proxy_options)

    # Merge with user options (user options take precedence)
    # Special handling for connect_options to deep merge with proxy config
    # Strip HTTPoison-style timeout keys that were handled by get_timeout/2,
    # and :max_response_bytes, which Req does not recognise
    user_opts_clean = Keyword.drop(user_options, [:timeout, :recv_timeout, :max_response_bytes])

    case Keyword.get(user_opts_clean, :connect_options) do
      nil ->
        Keyword.merge(options_with_proxy, user_opts_clean)

      user_connect_opts ->
        proxy_connect_opts = Keyword.get(options_with_proxy, :connect_options, [])
        merged_connect_opts = Keyword.merge(proxy_connect_opts, user_connect_opts)

        # Cannot use both :finch and :connect_options (Req limitation)
        options_with_proxy
        |> Keyword.delete(:connect_options)
        |> Keyword.delete(:finch)
        |> Keyword.merge(Keyword.delete(user_opts_clean, :connect_options))
        |> Keyword.put(:connect_options, merged_connect_opts)
    end
  end

  # Req 0.7 moved the Finch adapter's settings under a keyword list; the bare
  # `finch: name` form still works but is deprecated and goes away in 0.8.
  defp req_transport_option do
    case Application.get_env(:tymeslot, :req_test_plug) do
      nil -> {:finch, [name: Tymeslot.Finch]}
      plug -> {:plug, plug}
    end
  end

  defp normalize_method(method) when method in @standard_methods, do: method

  defp normalize_method(method) when is_atom(method) do
    method |> Atom.to_string() |> String.upcase()
  end

  @spec get_proxy_options(String.t()) :: keyword()
  defp get_proxy_options(url) do
    # Get proxy config for this URL (considers NO_PROXY and URL scheme)
    proxy_config = ProxyConfig.get_proxy_for_url(url)

    # Log proxy usage for debugging. Scheme and host only, never the path or
    # query: some destinations (the Telegram Bot API) carry their credential
    # in the URL path, and this debug log is not the place to re-derive which
    # paths are safe to print.
    if proxy_config do
      Logger.debug("Using proxy for request",
        proxy: "#{proxy_config.host}:#{proxy_config.port}",
        url: log_safe_origin(url)
      )
    end

    # Build Req-compatible proxy options
    ProxyConfig.build_req_proxy_options(proxy_config)
  end

  @spec get_timeout(atom(), keyword()) :: non_neg_integer()
  defp get_timeout(method, user_options) do
    cond do
      # User-provided timeout takes highest precedence
      user_options[:timeout] ->
        user_options[:timeout]

      user_options[:receive_timeout] ->
        user_options[:receive_timeout]

      # Otherwise use operation-specific timeout
      true ->
        Map.get(@operation_timeouts, method, 30_000)
    end
  end

  @spec track_request(atom(), String.t(), (-> {:ok, Response.t()} | {:error, Exception.t()})) ::
          {:ok, Response.t()} | {:error, Exception.t()}
  defp track_request(method, url, request_fn) when is_atom(method) do
    start_time = System.monotonic_time()

    result = request_fn.()

    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    status_code =
      case result do
        {:ok, %{status: code}} -> code
        _error -> 0
      end

    Metrics.track_http_request(to_string(method), url, status_code, duration_ms)

    result
  end
end
