defmodule TymeslotWeb.Helpers.ClientIP do
  @moduledoc """
  Provides a standardized way to extract client IP addresses from both
  Plug.Conn (for controllers) and Phoenix.LiveView.Socket (for LiveViews).

  Handles various scenarios including:
  - Direct connections
  - Reverse proxy headers (X-Real-IP, X-Forwarded-For)
  - LiveView socket assigns
  - Fallback to "unknown" when IP cannot be determined
  """

  alias Phoenix.LiveView
  alias Plug.Conn

  @doc """
  Extracts the client IP address from a Plug.Conn or Phoenix.LiveView.Socket.

  IMPORTANT: For LiveViews, this function is safe to call at any time (mount/events),
  but it will ONLY ever read from socket assigns. It will never access connect_info
  or connect_params to avoid runtime errors outside mount.

  If you need to read the client IP during mount, use `get_from_mount/1` to capture it
  and store it under :client_ip in assigns for later use.

  ## Examples

      # In a controller
      client_ip = ClientIP.get(conn)

      # In a LiveView (post-mount)
      client_ip = ClientIP.get(socket)

  ## Returns

  A string representation of the IP address, or "unknown" if it cannot be determined.
  """
  @spec get(Plug.Conn.t() | Phoenix.LiveView.Socket.t()) :: String.t()
  def get(%Plug.Conn{} = conn) do
    get_from_conn(conn)
  end

  def get(%Phoenix.LiveView.Socket{} = socket) do
    get_from_socket_assigns(socket)
  end

  def get(_), do: "unknown"

  @doc """
  Reads client IP using LiveView connect_info/connect_params. This MUST be called
  only during mount/3 of the root LiveView. Typical usage is to read the value
  and immediately store it in socket assigns for later usage.

  IMPORTANT: Checks forwarded headers FIRST (x-forwarded-for, x-real-ip) before
  falling back to peer_data. This is critical when behind a reverse proxy like
  Cloudron, Nginx, etc., where peer_data would return the proxy's internal IP.
  """
  @spec get_from_mount(Phoenix.LiveView.Socket.t()) :: String.t()
  def get_from_mount(%Phoenix.LiveView.Socket{} = socket) do
    # Try forwarded headers first (critical for reverse proxy setups)
    forwarded_ip = get_forwarded_from_socket(socket)
    peer_ip = get_from_connect_info(socket)

    case forwarded_ip do
      "unknown" -> peer_ip
      ip -> ip
    end
  end

  @doc """
  Extracts the user agent from a Plug.Conn or Phoenix.LiveView.Socket.

  IMPORTANT: For LiveViews, this function is safe to call at any time (mount/events),
  but it will ONLY read from assigns.

  If you need to read the user agent during mount, use `get_user_agent_from_mount/1`
  and store it under :user_agent in assigns for later use.
  """
  @spec get_user_agent(Plug.Conn.t() | Phoenix.LiveView.Socket.t()) :: String.t()
  def get_user_agent(%Plug.Conn{} = conn) do
    get_user_agent_from_conn(conn)
  end

  def get_user_agent(%Phoenix.LiveView.Socket{} = socket) do
    get_user_agent_from_socket(socket)
  end

  def get_user_agent(_), do: "unknown"

  @doc """
  Reads user-agent from LiveView connect params (headers). Call only during mount/3
  and then store it in assigns for later usage.
  """
  @spec get_user_agent_from_mount(Phoenix.LiveView.Socket.t()) :: String.t()
  def get_user_agent_from_mount(%Phoenix.LiveView.Socket{} = socket) do
    with %{} = params <- LiveView.get_connect_params(socket),
         headers when is_map(headers) <- Map.get(params, "headers", %{}),
         ua when is_binary(ua) <- Map.get(headers, "user-agent") do
      ua
    else
      _ -> "unknown"
    end
  end

  # Private functions for Plug.Conn

  defp get_from_conn(conn) do
    # Prefer conn.remote_ip (with Plug.RemoteIp configured in Endpoint)
    ip = get_remote_ip(conn)

    if ip != "unknown" do
      ip
    else
      # Fallback to common proxy headers when remote_ip cannot be determined
      case get_real_ip_header(conn) do
        {:ok, header_ip} -> header_ip
        :error -> fallback_unknown_conn_ip()
      end
    end
  end

  defp get_real_ip_header(conn) do
    # Check X-Real-IP first (more specific)
    case Conn.get_req_header(conn, "x-real-ip") do
      [real_ip | _] ->
        {:ok, String.trim(real_ip)}

      [] ->
        # Then check X-Forwarded-For
        case Conn.get_req_header(conn, "x-forwarded-for") do
          [forwarded | _] ->
            # X-Forwarded-For can contain multiple IPs, take the first (original client)
            ip = forwarded |> String.split(",") |> List.first() |> String.trim()
            {:ok, ip}

          [] ->
            :error
        end
    end
  end

  defp get_remote_ip(conn) do
    case conn.remote_ip do
      {_, _, _, _} = ip_tuple ->
        inet_ntoa_to_string(ip_tuple)

      {_, _, _, _, _, _, _, _} = ip_tuple ->
        inet_ntoa_to_string(ip_tuple)

      _ ->
        "unknown"
    end
  end

  defp inet_ntoa_to_string(ip_tuple) do
    case :inet.ntoa(ip_tuple) do
      {:error, _reason} -> "unknown"
      charlist when is_list(charlist) -> to_string(charlist)
    end
  end

  # When tests construct bare `%Plug.Conn{}` structs, `remote_ip` is unset and there are no
  # request headers. Returning a constant value like "unknown" causes rate-limiter buckets
  # (e.g. signup-by-ip) to collide across unrelated async tests.
  #
  # To keep production semantics intact, we only synthesize a deterministic per-process
  # IP in the test environment.
  defp fallback_unknown_conn_ip do
    case Application.get_env(:tymeslot, :environment) do
      :test ->
        # Each ExUnit test runs in its own process, so this avoids cross-test collisions
        # while staying stable within a single test.
        last_octet = rem(:erlang.phash2(self()), 250) + 1
        "127.0.0.#{last_octet}"

      _ ->
        "unknown"
    end
  end

  # Private functions for Phoenix.LiveView.Socket

  # Safe variant: only look at assigns for LiveView sockets. Never reads connect info here.
  defp get_from_socket_assigns(socket) do
    case socket.assigns[:client_ip] || socket.assigns[:remote_ip] do
      ip when is_binary(ip) -> ip
      _ -> "unknown"
    end
  end

  # Only call from get_from_mount/1
  defp get_from_connect_info(socket) do
    case LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} ->
        address |> :inet.ntoa() |> to_string()

      _ ->
        "unknown"
    end
  end

  # Only call from get_from_mount/1
  # Reads x-headers from connect_info (configured in endpoint.ex socket options)
  defp get_forwarded_from_socket(socket) do
    # LiveView's :x_headers option provides headers as a list of {name, value} tuples
    case LiveView.get_connect_info(socket, :x_headers) do
      headers when is_list(headers) ->
        extract_forwarded_ip_from_tuples(headers)

      _ ->
        # Fallback to connect_params (client-side headers)
        get_forwarded_from_connect_params(socket)
    end
  end

  defp get_forwarded_from_connect_params(socket) do
    with %{} = connect_params <- LiveView.get_connect_params(socket),
         headers when is_map(headers) <- Map.get(connect_params, "headers", %{}),
         ip when is_binary(ip) <- extract_forwarded_ip_from_map(headers) do
      ip
    else
      _ -> "unknown"
    end
  end

  defp extract_forwarded_ip_from_tuples(headers) do
    # Headers are [{name, value}, ...] tuples from :x_headers connect_info
    x_real_ip = find_header(headers, "x-real-ip")
    x_forwarded_for = find_header(headers, "x-forwarded-for")

    cond do
      x_real_ip != nil ->
        String.trim(x_real_ip)

      x_forwarded_for != nil ->
        # Take the first IP from x-forwarded-for chain
        x_forwarded_for |> String.split(",") |> List.first() |> String.trim()

      true ->
        "unknown"
    end
  end

  defp find_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      _ -> nil
    end
  end

  defp extract_forwarded_ip_from_map(headers) do
    # Check for various header formats (headers might be lowercase)
    cond do
      Map.has_key?(headers, "x-real-ip") ->
        String.trim(Map.get(headers, "x-real-ip"))

      Map.has_key?(headers, "x-forwarded-for") ->
        String.trim(List.first(String.split(headers["x-forwarded-for"], ",")))

      true ->
        nil
    end
  end

  # Private functions for User Agent extraction

  defp get_user_agent_from_conn(conn) do
    case Conn.get_req_header(conn, "user-agent") do
      [user_agent | _] -> user_agent
      [] -> "unknown"
    end
  end

  defp get_user_agent_from_socket(socket) do
    # Check if user agent was stored in assigns
    case socket.assigns[:user_agent] do
      agent when is_binary(agent) ->
        agent

      _ ->
        "unknown"
    end
  end
end
