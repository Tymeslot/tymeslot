defmodule TymeslotWeb.Helpers.ClientIP do
  @moduledoc """
  Provides a standardized way to extract client IP addresses from both
  Plug.Conn (for controllers) and Phoenix.LiveView.Socket (for LiveViews).

  Handles various scenarios including:
  - Direct connections
  - Reverse proxy headers (CF-Connecting-IP, X-Real-IP, X-Forwarded-For)
  - Cloudflare deployments (CF-Connecting-IP takes highest precedence)
  - LiveView socket assigns
  - Fallback to "unknown" when IP cannot be determined
  """

  alias Phoenix.LiveView
  alias Plug.Conn
  alias Tymeslot.Security.PrivateIPv6

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

  def get(_other), do: "unknown"

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

  def get_user_agent(_other), do: "unknown"

  @doc """
  Reads user-agent from LiveView connect params (headers). Call only during mount/3
  and then store it in assigns for later usage.
  """
  @spec get_user_agent_from_mount(Phoenix.LiveView.Socket.t()) :: String.t()
  def get_user_agent_from_mount(%Phoenix.LiveView.Socket{} = socket) do
    # Prefer connect_info (server-side) when available. This works with the standard
    # LiveView WebSocket connection as long as the endpoint includes :user_agent in
    # connect_info.
    case LiveView.get_connect_info(socket, :user_agent) do
      ua when is_binary(ua) and ua != "" ->
        ua

      _other ->
        with %{} = params <- LiveView.get_connect_params(socket),
             headers when is_map(headers) <- Map.get(params, "headers", %{}),
             ua when is_binary(ua) <- Map.get(headers, "user-agent"),
             true <- ua != "" do
          ua
        else
          _other -> "unknown"
        end
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
    # Last-resort fallback: effectively unreachable in production behind Plug.RemoteIp,
    # which always sets conn.remote_ip to a tuple (causing get_remote_ip/1 to succeed).
    # Retained for bare %Plug.Conn{} construction in tests or unusual deployment
    # configurations where RemoteIp is not in the plug pipeline.
    # Precedence: cf-connecting-ip > x-real-ip > x-forwarded-for.
    case Conn.get_req_header(conn, "cf-connecting-ip") do
      [cf_ip | _rest] ->
        {:ok, String.trim(cf_ip)}

      [] ->
        case Conn.get_req_header(conn, "x-real-ip") do
          [real_ip | _rest] ->
            {:ok, String.trim(real_ip)}

          [] ->
            case Conn.get_req_header(conn, "x-forwarded-for") do
              [forwarded | _rest] ->
                # X-Forwarded-For can contain multiple IPs, take the first (original client)
                ip = forwarded |> String.split(",") |> List.first() |> String.trim()
                {:ok, ip}

              [] ->
                :error
            end
        end
    end
  end

  defp get_remote_ip(conn) do
    case conn.remote_ip do
      {_a, _b, _c, _d} = ip_tuple ->
        inet_ntoa_to_string(ip_tuple)

      {_s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8} = ip_tuple ->
        inet_ntoa_to_string(ip_tuple)

      _other ->
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

      _other ->
        "unknown"
    end
  end

  # Private functions for Phoenix.LiveView.Socket

  # Safe variant: only look at assigns for LiveView sockets. Never reads connect info here.
  defp get_from_socket_assigns(socket) do
    case socket.assigns[:client_ip] || socket.assigns[:remote_ip] do
      ip when is_binary(ip) -> ip
      _other -> "unknown"
    end
  end

  # Only call from get_from_mount/1
  #
  # The address is unmapped before formatting so a dual-stack listener yields
  # "203.0.113.5" rather than "::ffff:203.0.113.5" — the same string the conn
  # path produces for that client, so both paths share one rate-limit bucket.
  defp get_from_connect_info(socket) do
    case LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} ->
        address |> PrivateIPv6.unmap() |> :inet.ntoa() |> to_string()

      _other ->
        "unknown"
    end
  end

  # Only call from get_from_mount/1
  # Reads x-headers from connect_info (configured in endpoint.ex socket options).
  # Forwarded headers are only trusted when the direct peer (socket's TCP source)
  # is a private/loopback address — i.e. a trusted local reverse proxy. A client
  # connecting directly from a public IP cannot inject a spoofed forwarded header.
  defp get_forwarded_from_socket(socket) do
    peer_address =
      case LiveView.get_connect_info(socket, :peer_data) do
        %{address: addr} -> addr
        _other -> nil
      end

    if trusted_peer?(peer_address) do
      case LiveView.get_connect_info(socket, :x_headers) do
        headers when is_list(headers) ->
          extract_forwarded_ip_from_tuples(headers)

        _other ->
          # Fallback to connect_params (client-supplied headers); only reached
          # when connect_info is unavailable (e.g. embed socket without session).
          get_forwarded_from_connect_params(socket)
      end
    else
      # Direct connection from a non-private peer: ignore forwarded headers to
      # prevent IP spoofing; caller will use peer_data instead.
      "unknown"
    end
  end

  # Returns true when address is a loopback or RFC-1918/4193 private range,
  # the same ranges that Plug.RemoteIp trusts on the conn path in production.
  #
  # The peer is normalised first: a dual-stack listener reports an IPv4 proxy as
  # the IPv4-mapped `::ffff:172.18.0.1`, an 8-element tuple that matches none of
  # the IPv4 clauses below. Left unmapped, every socket-path request behind the
  # reverse proxy is treated as untrusted, the forwarded headers are dropped and
  # `get_from_mount/1` falls back to the proxy's own address — collapsing every
  # IP-keyed rate limit into a single bucket shared by all visitors.
  #
  # Deliberately narrower than `PrivateIPv4.private?/1`, which also covers
  # 0.0.0.0/8, 100.64/10 and 169.254/16: that predicate answers "is this
  # unroutable?" for SSRF, whereas this one answers "may this peer speak for
  # someone else?". Trusting a CGNAT or link-local peer would let a client
  # forge `x-forwarded-for` and evade the rate limits keyed on it.
  defp trusted_peer?(nil), do: false

  defp trusted_peer?({0, 0, 0, 0, 0, 0xFFFF, _hi, _lo} = address),
    do: address |> PrivateIPv6.unmap() |> trusted_peer?()

  # IPv4 loopback: 127.0.0.0/8
  defp trusted_peer?({127, _b, _c, _d}), do: true

  # IPv4 private: 10.0.0.0/8
  defp trusted_peer?({10, _b, _c, _d}), do: true

  # IPv4 private: 172.16.0.0/12 (172.16.0.0 – 172.31.255.255)
  defp trusted_peer?({172, b, _c, _d}) when b in 16..31, do: true

  # IPv4 private: 192.168.0.0/16
  defp trusted_peer?({192, 168, _c, _d}), do: true

  # IPv6 loopback: ::1
  defp trusted_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv6 unique-local (fc00::/7 covers fc00:: and fd00::)
  defp trusted_peer?({fc, _b, _c, _d, _e, _f, _g, _h}) when fc in 0xFC00..0xFDFF, do: true

  defp trusted_peer?(_addr), do: false

  defp get_forwarded_from_connect_params(socket) do
    with %{} = connect_params <- LiveView.get_connect_params(socket),
         headers when is_map(headers) <- Map.get(connect_params, "headers", %{}),
         ip when is_binary(ip) <- extract_forwarded_ip_from_map(headers) do
      ip
    else
      _other -> "unknown"
    end
  end

  defp extract_forwarded_ip_from_tuples(headers) do
    # Headers are [{name, value}, ...] tuples from :x_headers connect_info.
    # Phoenix's :x_headers collects only headers whose name starts with "x-",
    # so CF-Connecting-IP (no "x-" prefix) is never present on the socket path.
    # Resolution uses x-real-ip (trusted upstream proxy, e.g. Nginx) then
    # x-forwarded-for (first hop only). Only called when the direct peer is a
    # trusted private/loopback address (see get_forwarded_from_socket/1).
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
      _other -> nil
    end
  end

  defp extract_forwarded_ip_from_map(headers) do
    # Check for various header formats (headers might be lowercase).
    # Same precedence as extract_forwarded_ip_from_tuples/1.
    cond do
      Map.has_key?(headers, "cf-connecting-ip") ->
        String.trim(Map.get(headers, "cf-connecting-ip"))

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
      [user_agent | _rest] -> user_agent
      [] -> "unknown"
    end
  end

  defp get_user_agent_from_socket(socket) do
    # Check if user agent was stored in assigns
    case socket.assigns[:user_agent] do
      agent when is_binary(agent) ->
        agent

      _other ->
        "unknown"
    end
  end
end
