defmodule Tymeslot.Infrastructure.HTTPClient do
  @moduledoc """
  Standardized HTTP client for the application.
  Wraps Req and provides consistent interface for all HTTP requests.
  """

  @behaviour Tymeslot.Infrastructure.HTTPClientBehaviour

  require Logger
  alias Tymeslot.Infrastructure.{Metrics, ProxyConfig}

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
  Performs a GET request.
  """
  @spec get(String.t(), list(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def get(url, headers \\ [], options \\ []) do
    request(:get, url, "", headers, options)
  end

  @doc """
  Performs a POST request.
  """
  @spec post(String.t(), any(), list(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def post(url, body, headers \\ [], options \\ []) do
    request(:post, url, body, headers, options)
  end

  @doc """
  Performs a PUT request.
  """
  @spec put(String.t(), any(), list(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def put(url, body, headers \\ [], options \\ []) do
    request(:put, url, body, headers, options)
  end

  @doc """
  Performs a DELETE request.
  """
  @spec delete(String.t(), list(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def delete(url, headers \\ [], options \\ []) do
    request(:delete, url, "", headers, options)
  end

  @doc """
  Performs a HEAD request.
  """
  @spec head(String.t(), list(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def head(url, headers \\ [], options \\ []) do
    request(:head, url, "", headers, options)
  end

  @doc """
  Performs a REPORT request (CalDAV specific).
  """
  @spec report(String.t(), any(), list(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
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
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(method, url, body \\ "", headers \\ [], options \\ [])

  def request(method, url, body, headers, options) when is_atom(method) do
    req_options = build_req_options(method, url, body, headers, options)

    track_request(method, url, fn ->
      Req.request(req_options)
    end)
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

  @spec build_req_options(atom(), String.t(), any(), list(), keyword()) :: keyword()
  defp build_req_options(method, url, body, headers, user_options) do
    # Get timeout for this operation
    timeout = get_timeout(method, user_options)

    # Get proxy configuration for this URL (considers NO_PROXY, HTTP vs HTTPS)
    proxy_options = get_proxy_options(url)

    # Build base request options
    # NOTE: Cannot set both :finch and :connect_options (Req limitation)
    # When proxy is configured, connect_options will be set, so don't set finch
    base_options =
      if proxy_options == [] do
        [
          method: method,
          url: url,
          headers: headers,
          finch: Tymeslot.Finch,
          receive_timeout: timeout,
          # Disable automatic JSON decoding to match HTTPoison behavior
          # Callers handle JSON parsing explicitly with Jason.decode!
          decode_body: false
        ]
      else
        [
          method: method,
          url: url,
          headers: headers,
          receive_timeout: timeout,
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

    # Add proxy options if configured
    options_with_proxy = Keyword.merge(options_with_body, proxy_options)

    # Merge with user options (user options take precedence)
    # Special handling for connect_options to deep merge with proxy config
    # Strip HTTPoison-style timeout keys that were handled by get_timeout/2
    user_opts_clean = user_options |> Keyword.delete(:timeout) |> Keyword.delete(:recv_timeout)

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

  @spec get_proxy_options(String.t()) :: keyword()
  defp get_proxy_options(url) do
    # Get proxy config for this URL (considers NO_PROXY and URL scheme)
    proxy_config = ProxyConfig.get_proxy_for_url(url)

    # Log proxy usage for debugging
    if proxy_config do
      Logger.debug("Using proxy #{proxy_config.host}:#{proxy_config.port} for #{url}")
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

  @spec track_request(atom(), String.t(), (-> {:ok, Req.Response.t()} | {:error, Exception.t()})) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
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
