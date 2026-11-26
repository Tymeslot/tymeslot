defmodule Tymeslot.Integrations.Stripe.Request do
  @moduledoc """
  One Stripe API call described as data: internal to `Tymeslot.Integrations.Stripe`,
  built by the resource modules and sent by `Tymeslot.Integrations.Stripe.Client`.

  Everything here is pure. `operation` names the call (`:create_refund`,
  `:retrieve_charge`) for telemetry, logs and test stubs; `path` is the list of
  segments after `/v1`, each escaped on its own so an id can never reach another
  endpoint.

  `api_key` is set only when a caller passes one explicitly. The configured key is
  resolved by the client at send time, and `inspect/1` leaves the field out, so a
  request that ends up in a log or a crash report carries no secret.

  `deadline_ms` bounds the whole call, retries and waits included; the
  client caps each attempt's waits at the time left (see
  `Tymeslot.Integrations.Stripe.RetryPolicy.attempt_timeouts/2`). The
  connect timeout is fixed per connection pool and not capped, so a call may
  overrun its deadline by up to one `connect_timeout`.
  """

  alias Tymeslot.Integrations.Stripe.FormEncoder

  @timeouts [deadline_ms: 10_000, receive_timeout: 8_000, connect_timeout: 3_000]

  @fields [
    :operation,
    :method,
    :path,
    params: %{},
    api_key: nil,
    connect_account: nil,
    idempotency_key: nil
  ]

  @derive {Inspect, except: [:api_key]}
  defstruct @fields ++ @timeouts

  @type method :: :get | :post | :delete

  @type t :: %__MODULE__{
          operation: atom(),
          method: method(),
          path: [String.t()],
          params: map() | keyword(),
          api_key: String.t() | nil,
          connect_account: String.t() | nil,
          idempotency_key: String.t() | nil,
          deadline_ms: pos_integer(),
          receive_timeout: pos_integer(),
          connect_timeout: pos_integer()
        }

  @options [:api_key, :connect_account, :idempotency_key | @timeouts]

  @doc """
  Builds a request.

  Options: `:api_key`, `:connect_account`, `:idempotency_key`, `:deadline_ms`,
  `:receive_timeout`, `:connect_timeout`. Raises `ArgumentError` for a path
  segment that is not a non-empty binary, for an unknown option, so a
  misspelt option fails loudly instead of being ignored, for a timeout
  that is not a positive integer of milliseconds, and for a
  `connect_timeout` that leaves no time inside `deadline_ms`.
  """
  @spec new(atom(), method(), [String.t()], map() | keyword(), keyword()) :: t()
  def new(operation, method, path, params, opts \\ [])
      when is_atom(operation) and method in [:get, :post, :delete] and is_list(path) and
             (is_map(params) or is_list(params)) do
    Enum.each(path, &validate_segment!/1)
    opts = Keyword.validate!(opts, @options)
    Enum.each(@timeouts, fn {name, _default} -> validate_timeout!(name, opts[name]) end)
    validate_timeouts!(opts[:connect_timeout], opts[:deadline_ms])

    struct!(
      __MODULE__,
      [operation: operation, method: method, path: path, params: params] ++ opts
    )
  end

  defp validate_timeout!(_name, ms) when is_integer(ms) and ms > 0, do: :ok

  defp validate_timeout!(name, ms) do
    raise ArgumentError, "expected #{name} to be a positive integer, got: #{inspect(ms)}"
  end

  defp validate_timeouts!(connect_timeout, deadline_ms) when connect_timeout < deadline_ms,
    do: :ok

  defp validate_timeouts!(connect_timeout, deadline_ms) do
    raise ArgumentError,
          "expected connect_timeout (#{connect_timeout}) to be less than deadline_ms (#{deadline_ms})"
  end

  defp validate_segment!(segment) when is_binary(segment) and segment != "", do: :ok

  defp validate_segment!(segment) do
    raise ArgumentError,
          "expected each path segment to be a non-empty string, got: #{inspect(segment)}"
  end

  @doc ~S"""
  The request path, `"/v1/refunds/re_1"`, with each segment URI-encoded.
  """
  @spec url_path(t()) :: String.t()
  def url_path(%__MODULE__{path: path}) do
    "/v1/" <>
      Enum.map_join(path, "/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  @doc """
  The request headers. `api_key` must be resolved on the request by then.
  """
  @spec headers(t(), String.t()) :: [{String.t(), String.t()}]
  def headers(%__MODULE__{api_key: key} = request, api_version) when is_binary(key) do
    [
      {"authorization", "Bearer " <> key},
      {"stripe-version", api_version},
      {"accept", "application/json"},
      {"user-agent", "Tymeslot/" <> to_string(Application.spec(:tymeslot, :vsn))}
    ] ++ post_headers(request) ++ account_header(request)
  end

  defp post_headers(%__MODULE__{method: :post, idempotency_key: key}) when is_binary(key) do
    [{"content-type", "application/x-www-form-urlencoded"}, {"idempotency-key", key}]
  end

  defp post_headers(%__MODULE__{method: :post}),
    do: [{"content-type", "application/x-www-form-urlencoded"}]

  defp post_headers(%__MODULE__{}), do: []

  defp account_header(%__MODULE__{connect_account: nil}), do: []
  defp account_header(%__MODULE__{connect_account: account}), do: [{"stripe-account", account}]

  @doc """
  The form body of a POST, or the query string of a GET or DELETE (`nil` when
  there are no params).
  """
  @spec body_and_query(t()) :: {String.t() | nil, String.t() | nil}
  def body_and_query(%__MODULE__{method: :post, params: params}),
    do: {FormEncoder.encode(params), nil}

  def body_and_query(%__MODULE__{params: params}) do
    case FormEncoder.encode(params) do
      "" -> {nil, nil}
      query -> {nil, query}
    end
  end
end
