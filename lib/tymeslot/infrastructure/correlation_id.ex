defmodule Tymeslot.Infrastructure.CorrelationId do
  @moduledoc """
  Provides correlation ID functionality for request tracking across the system.

  Correlation IDs help trace requests through multiple services and log entries,
  making debugging and monitoring significantly easier.

  ## One id per HTTP request

  As an endpoint plug this module runs right after `Plug.RequestId` and settles
  both ids for the request:

    * `request_id` stays what `Plug.RequestId` chose (the inbound `x-request-id`,
      or a freshly generated one), unless that value fails `valid?/1`. The plug
      only checks an inbound id's length, so a value carrying any other
      characters is replaced here with a newly generated one, in the response
      header and the Logger metadata alike.
    * `correlation_id` is the inbound `x-correlation-id` when it passes
      `valid?/1`, so an upstream caller can deliberately propagate its own id;
      otherwise it is the `request_id`. Without such a caller the two are the
      same value.

  A malformed inbound `x-correlation-id` is ignored and never echoed. The
  response always carries `x-correlation-id` with the id the request settled on.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView.Socket
  alias Plug.Conn
  alias Plug.RequestId
  alias Tymeslot.Infrastructure.ErrorTracking

  @correlation_id_header "x-correlation-id"
  @correlation_id_key :correlation_id
  # `Plug.RequestId`'s default response header.
  @request_id_header "x-request-id"
  # Every id that reaches a log line, an error context or a response header must
  # match this: bounded, and free of anything that could forge a log line or
  # inject markup.
  @id_format ~r/\A[A-Za-z0-9_\-]{8,128}\z/

  @doc """
  Returns whether `id` is acceptable as a correlation or request id: 8 to 128
  characters of ASCII letters, digits, underscores and hyphens.
  """
  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id), do: Regex.match?(@id_format, id)
  def valid?(_id), do: false

  @doc """
  Generates a new correlation ID.

  Uses a UUID v4 for uniqueness.
  """
  @spec generate() :: String.t()
  def generate do
    UUID.uuid4()
  end

  @doc """
  Gets the correlation ID the plug settled on for this request, or `nil` when
  the plug has not run.

  The raw `x-correlation-id` request header is deliberately not read here: it is
  client-supplied, and only the plug validates it.
  """
  @spec get_from_conn(Plug.Conn.t()) :: String.t() | nil
  def get_from_conn(conn), do: conn.assigns[@correlation_id_key]

  @doc """
  Sets a correlation ID in a Plug.Conn.

  Stores it in both assigns and response headers.
  """
  @spec put_in_conn(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_in_conn(conn, correlation_id) do
    conn
    |> Conn.assign(@correlation_id_key, correlation_id)
    |> Conn.put_resp_header(@correlation_id_header, correlation_id)
  end

  @doc """
  Gets the correlation ID from a Phoenix.LiveView.Socket.
  """
  @spec get_from_socket(Socket.t()) :: String.t() | nil
  def get_from_socket(socket) do
    socket.assigns[@correlation_id_key]
  end

  @doc """
  Sets a correlation ID in a Phoenix.LiveView.Socket.
  """
  @spec put_in_socket(Socket.t(), String.t()) :: Socket.t()
  def put_in_socket(socket, correlation_id) do
    Component.assign(socket, @correlation_id_key, correlation_id)
  end

  @doc """
  Gets the correlation ID from the current process dictionary.

  This is useful for background jobs and GenServers.
  """
  @spec get_from_process() :: String.t() | nil
  def get_from_process do
    Process.get(@correlation_id_key)
  end

  @doc """
  Sets the correlation ID in the current process dictionary.
  """
  @spec put_in_process(String.t()) :: String.t()
  def put_in_process(correlation_id) do
    Process.put(@correlation_id_key, correlation_id)
    correlation_id
  end

  @doc """
  Ensures a socket carries a correlation ID, generating one if necessary.
  """
  @spec ensure(Socket.t()) :: {Socket.t(), String.t()}
  def ensure(%Socket{} = socket) do
    case get_from_socket(socket) do
      nil ->
        correlation_id = generate()
        {put_in_socket(socket, correlation_id), correlation_id}

      existing_id ->
        {socket, existing_id}
    end
  end

  @doc """
  Creates a plug for automatically handling correlation IDs.

  Add this to your endpoint or router pipeline:

      plug Tymeslot.Infrastructure.CorrelationId
  """
  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Conn.t(), any()) :: Conn.t()
  def call(conn, _options) do
    # Clear any stale per-request state left behind by a previous request on
    # the same reused worker process. The ids are derived from this request's
    # headers below, never from the process dictionary.
    Process.delete(@correlation_id_key)

    {conn, request_id} = ensure_request_id(conn)
    correlation_id = inbound_correlation_id(conn) || request_id

    # Tag this request's log lines and any exception it raises. Setting
    # `request_id` here also overwrites `Plug.RequestId`'s Logger metadata when
    # its value was replaced above.
    ErrorTracking.put_context(correlation_id: correlation_id, request_id: request_id)

    # Also put in process dictionary for non-plug code
    put_in_process(correlation_id)

    put_in_conn(conn, correlation_id)
  end

  # `Plug.RequestId` runs just before this plug in the endpoint; without it (or
  # when its id fails the format) a fresh id is generated the way it would.
  defp ensure_request_id(conn) do
    case Conn.get_resp_header(conn, @request_id_header) do
      [request_id | _rest] ->
        if valid?(request_id), do: {conn, request_id}, else: put_new_request_id(conn)

      [] ->
        put_new_request_id(conn)
    end
  end

  defp put_new_request_id(conn) do
    request_id = RequestId.generate()
    {Conn.put_resp_header(conn, @request_id_header, request_id), request_id}
  end

  defp inbound_correlation_id(conn) do
    case Conn.get_req_header(conn, @correlation_id_header) do
      [correlation_id | _rest] -> if valid?(correlation_id), do: correlation_id
      [] -> nil
    end
  end
end
