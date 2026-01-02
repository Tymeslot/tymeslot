defmodule Tymeslot.Infrastructure.CorrelationId do
  @moduledoc """
  Provides correlation ID functionality for request tracking across the system.

  Correlation IDs help trace requests through multiple services and log entries,
  making debugging and monitoring significantly easier.
  """

  require Logger

  alias Phoenix.Component
  alias Phoenix.LiveView.Socket
  alias Plug.Conn

  @correlation_id_header "x-correlation-id"
  @correlation_id_key :correlation_id

  @doc """
  Generates a new correlation ID.

  Uses a UUID v4 for uniqueness.
  """
  @spec generate() :: String.t()
  def generate do
    UUID.uuid4()
  end

  @doc """
  Gets the correlation ID from a Plug.Conn.

  First checks for an existing correlation ID in the request headers,
  then checks assigns. If none found, returns nil.
  """
  @spec get_from_conn(Plug.Conn.t()) :: String.t() | nil
  def get_from_conn(conn) do
    # Check headers first (for incoming requests)
    case Conn.get_req_header(conn, @correlation_id_header) do
      [correlation_id | _] -> correlation_id
      [] -> conn.assigns[@correlation_id_key]
    end
  end

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
  Ensures a correlation ID exists, generating one if necessary.

  For Plug.Conn, checks headers and assigns, generates if missing.
  For Socket, checks assigns, generates if missing.
  """
  @spec ensure(Conn.t() | Socket.t()) ::
          {Conn.t() | Socket.t(), String.t()}
  def ensure(%Conn{} = conn) do
    case get_from_conn(conn) do
      nil ->
        correlation_id = generate()
        {put_in_conn(conn, correlation_id), correlation_id}

      existing_id ->
        {conn, existing_id}
    end
  end

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
  Adds correlation ID to log metadata.

  This should be called at the beginning of request processing to ensure
  all subsequent log entries include the correlation ID.
  """
  @spec add_to_logger_metadata(String.t()) :: :ok
  def add_to_logger_metadata(correlation_id) do
    Logger.metadata(correlation_id: correlation_id)
  end

  @doc """
  Wraps a function call with correlation ID tracking.

  Useful for background jobs and async operations.

  ## Examples

      CorrelationId.with_correlation_id(fn ->
        # Your code here - all logs will include the correlation ID
        process_order(order)
      end)

      # With existing correlation ID
      CorrelationId.with_correlation_id(correlation_id, fn ->
        send_email(user)
      end)
  """
  @spec with_correlation_id(String.t() | nil, function()) :: any()
  def with_correlation_id(correlation_id \\ nil, fun) do
    correlation_id = correlation_id || generate()

    # Store in process dictionary
    put_in_process(correlation_id)

    # Add to logger metadata
    add_to_logger_metadata(correlation_id)

    # Execute the function
    fun.()
  end

  @doc """
  Creates a plug for automatically handling correlation IDs.

  Add this to your endpoint or router pipeline:

      plug Tymeslot.Infrastructure.CorrelationId
  """
  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Conn.t(), any()) :: Conn.t()
  def call(conn, _opts) do
    {updated_conn, correlation_id} = ensure(conn)

    # Add to logger metadata for this request
    add_to_logger_metadata(correlation_id)

    # Also put in process dictionary for non-plug code
    put_in_process(correlation_id)

    updated_conn
  end
end
