defmodule Tymeslot.Infrastructure.HTTPClient do
  @moduledoc """
  Standardized HTTP client for the application.
  Wraps HTTPoison and provides support for custom HTTP methods.
  """

  @behaviour Tymeslot.Infrastructure.HTTPClientBehaviour

  require Logger
  alias Tymeslot.Infrastructure.{ConnectionPool, Metrics}

  @default_options [
    timeout: 30_000,
    recv_timeout: 30_000
  ]

  @operation_timeouts %{
    # Read operations get standard timeout
    get: [timeout: 30_000, recv_timeout: 30_000],

    # Write operations get longer timeout
    post: [timeout: 45_000, recv_timeout: 45_000],
    put: [timeout: 45_000, recv_timeout: 45_000],
    delete: [timeout: 45_000, recv_timeout: 45_000],

    # REPORT can be slow with large calendars
    report: [timeout: 60_000, recv_timeout: 60_000]
  }

  @doc """
  Performs a GET request.
  """
  @spec get(String.t(), list(), keyword()) ::
          {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  def get(url, headers \\ [], options \\ []) do
    options = merge_options(options, :get, url)
    track_request(:get, url, fn -> HTTPoison.get(url, headers, options) end)
  end

  @doc """
  Performs a POST request.
  """
  @spec post(String.t(), any(), list(), keyword()) ::
          {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  def post(url, body, headers \\ [], options \\ []) do
    options = merge_options(options, :post, url)
    track_request(:post, url, fn -> HTTPoison.post(url, body, headers, options) end)
  end

  @doc """
  Performs a PUT request.
  """
  @spec put(String.t(), any(), list(), keyword()) ::
          {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  def put(url, body, headers \\ [], options \\ []) do
    options = merge_options(options, :put, url)
    track_request(:put, url, fn -> HTTPoison.put(url, body, headers, options) end)
  end

  @doc """
  Performs a DELETE request.
  """
  @spec delete(String.t(), list(), keyword()) ::
          {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  def delete(url, headers \\ [], options \\ []) do
    options = merge_options(options, :delete, url)
    track_request(:delete, url, fn -> HTTPoison.delete(url, headers, options) end)
  end

  @doc """
  Performs a REPORT request (CalDAV specific).
  Uses hackney directly as HTTPoison doesn't support custom methods.
  """
  @spec report(String.t(), any(), list(), keyword()) ::
          {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  def report(url, body, headers \\ [], options \\ []) do
    options = merge_options(options, :report, url)
    hackney_opts = convert_to_hackney_options(options)

    track_request(:report, url, fn ->
      case :hackney.request("REPORT", url, headers, body, [{:with_body, true} | hackney_opts]) do
        {:ok, status_code, response_headers, response_body} ->
          # Convert to HTTPoison-like response format
          {:ok,
           %HTTPoison.Response{
             status_code: status_code,
             headers: response_headers,
             body: response_body,
             request_url: url,
             request: %HTTPoison.Request{
               method: :report,
               url: url,
               headers: headers,
               body: body,
               options: options
             }
           }}

        {:error, reason} ->
          {:error, %HTTPoison.Error{reason: reason}}
      end
    end)
  end

  @allowed_methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete,
    "head" => :head,
    "options" => :options,
    "report" => :report
  }

  @doc """
  Performs any custom HTTP method request.
  """
  @spec request(atom() | String.t(), String.t(), any(), list(), keyword()) ::
          {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  def request(method, url, body \\ "", headers \\ [], options \\ [])

  def request(method, url, body, headers, options) when is_atom(method) do
    options = merge_options(options, method, url)
    track_request(method, url, fn -> HTTPoison.request(method, url, body, headers, options) end)
  end

  def request(method, url, body, headers, options) when is_binary(method) do
    downcased = String.downcase(method)

    case Map.fetch(@allowed_methods, downcased) do
      {:ok, atom_method} ->
        request(atom_method, url, body, headers, options)

      :error ->
        {:error, %HTTPoison.Error{reason: {:invalid_method, method}}}
    end
  end

  def request(method, _url, _body, _headers, _options) do
    {:error, %HTTPoison.Error{reason: {:invalid_method, method}}}
  end

  # Private functions

  @spec track_request(atom(), String.t(), (-> {:ok, HTTPoison.Response.t()}
                                                           | {:error, HTTPoison.Error.t()})) ::
          {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  defp track_request(method, url, request_fn) when is_atom(method) do
    start_time = System.monotonic_time()

    result = request_fn.()

    duration = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    status_code =
      case result do
        {:ok, %{status_code: code}} -> code
        _ -> 0
      end

    Metrics.track_http_request(to_string(method), url, status_code, duration_ms)

    result
  end

  @doc """
  Merges user-provided options with operation-specific defaults.

  Applies the following precedence (highest to lowest):
  1. User-provided options
  2. Connection pool configuration
  3. Configured operation-specific timeouts
  4. Default operation timeouts
  5. Base defaults
  """
  @spec merge_options(keyword(), atom(), String.t()) :: keyword()
  def merge_options(user_options, operation, url) do
    # Get configured timeouts if available
    configured_timeouts = Application.get_env(:tymeslot, :http_timeouts, %{})

    # Start with operation-specific timeouts, fall back to defaults
    base_options = Map.get(@operation_timeouts, operation, @default_options)

    # Apply configured timeouts for this operation if any
    operation_config = Map.get(configured_timeouts, operation, [])

    # Add connection pool based on URL
    pool = ConnectionPool.get_pool(url)
    pool_options = [hackney: [pool: pool]]

    # User options override everything
    @default_options
    |> Keyword.merge(base_options)
    |> Keyword.merge(operation_config)
    |> Keyword.merge(pool_options)
    |> Keyword.merge(user_options)
  end

  defp convert_to_hackney_options(httpoison_options) do
    hackney_opts = []

    hackney_opts =
      if httpoison_options[:timeout] do
        [{:connect_timeout, httpoison_options[:timeout]} | hackney_opts]
      else
        hackney_opts
      end

    hackney_opts =
      if httpoison_options[:recv_timeout] do
        [{:recv_timeout, httpoison_options[:recv_timeout]} | hackney_opts]
      else
        hackney_opts
      end

    hackney_opts =
      if httpoison_options[:ssl] do
        [{:ssl_options, httpoison_options[:ssl]} | hackney_opts]
      else
        hackney_opts
      end

    # Extract pool from hackney options if present
    hackney_opts =
      if httpoison_options[:hackney] && httpoison_options[:hackney][:pool] do
        [{:pool, httpoison_options[:hackney][:pool]} | hackney_opts]
      else
        [{:pool, :default} | hackney_opts]
      end

    hackney_opts
  end
end
