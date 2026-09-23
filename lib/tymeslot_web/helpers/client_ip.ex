defmodule TymeslotWeb.Helpers.ClientIP do
  @moduledoc """
  Provides a standardized way to extract client IP addresses from both
  Plug.Conn (for controllers) and Phoenix.LiveView.Socket (for LiveViews).

  Handles various scenarios including:
  - Direct connections
  - Reverse proxy headers (X-Forwarded-For, X-Real-IP)
  - LiveView socket assigns
  - Fallback to "unknown" when IP cannot be determined

  ## One resolution rule for both paths

  The conn path is resolved by the endpoint's `RemoteIp` plug: the entries of
  `X-Forwarded-For` and `X-Real-IP` are read in the order the headers arrived,
  and the rightmost one that is not a proxy hop names the visitor. The socket
  path (`get_from_mount/1`) applies the same rule to the same two headers, so
  neither header outranks the other. Giving `X-Real-IP` precedence on the
  socket alone let one visitor resolve to two addresses, and therefore two
  rate-limit buckets, depending on whether a request arrived over HTTP or the
  LiveView socket. A deployment whose proxy sets only `X-Real-IP` still
  resolves from it, since it is the only entry.
  """

  alias Phoenix.LiveView
  alias Plug.Conn
  alias Tymeslot.Security.PrivateIPv6

  # The ranges `trusted_peer?/1` matches, in the CIDR form `RemoteIp` takes.
  @private_client_blocks ~w[127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 ::1/128 fc00::/7]

  # The forwarded headers the socket path reads: the same two, and only those,
  # that the endpoint's `RemoteIp` plug is configured with.
  @forwarded_headers ~w[x-forwarded-for x-real-ip]

  @doc """
  The `clients:` list for the endpoint's `RemoteIp` plug: the conn path's half
  of `:trust_private_client_ips`.

  `RemoteIp` skips a forwarded address in a reserved block unless `clients:`
  names it (`proxies:` cannot, as `RemoteIp.type/2` consults it only after
  `clients:`), so this returns the private blocks when the flag is on and
  nothing otherwise. Reading the same flag as `get_from_mount/1` is what keeps
  the conn and socket paths from being configured apart.
  """
  @spec remote_ip_clients() :: [String.t()]
  def remote_ip_clients, do: remote_ip_clients(trust_private_clients?())

  @doc false
  @spec remote_ip_clients(boolean()) :: [String.t()]
  def remote_ip_clients(true), do: @private_client_blocks
  def remote_ip_clients(false), do: []

  @doc """
  Parses the `TRUST_PRIVATE_CLIENT_IPS` environment variable into the boolean
  `config/runtime.exs` stores under `:trust_private_client_ips`.

  Accepts `"true"`, `"1"` or `"yes"` (case-sensitive); anything else,
  including unset (`nil`), leaves the flag off, the fail-safe default for an
  internet-facing deployment.
  """
  @spec trust_private_clients_from_env(String.t() | nil) :: boolean()
  def trust_private_clients_from_env(value), do: value in ~w[true 1 yes]

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

  IMPORTANT: Checks forwarded headers FIRST (x-forwarded-for and x-real-ip,
  resolved as the moduledoc describes) before falling back to peer_data. This is critical when behind a reverse proxy like
  Cloudron, Nginx, etc., where peer_data would return the proxy's internal IP.
  """
  @spec get_from_mount(Phoenix.LiveView.Socket.t()) :: String.t()
  def get_from_mount(%Phoenix.LiveView.Socket{} = socket) do
    get_from_mount(socket, trust_private_clients?())
  end

  @doc false
  # Same as `get_from_mount/1`, with the `:trust_private_client_ips` decision
  # supplied rather than read from config.
  #
  # The flag is threaded in as an argument so that both of its states are
  # reachable from a test without mutating global application env in an async
  # suite. Production has exactly one call site, `get_from_mount/1` above, which
  # reads the configured value.
  @spec get_from_mount(Phoenix.LiveView.Socket.t(), boolean()) :: String.t()
  def get_from_mount(%Phoenix.LiveView.Socket{} = socket, trust_private_clients?)
      when is_boolean(trust_private_clients?) do
    # Try forwarded headers first (critical for reverse proxy setups)
    forwarded_ip = get_forwarded_from_socket(socket, trust_private_clients?)
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
    #
    # Unreachable or not, it applies the same hop filtering as the socket path
    # and as RemoteIp: leftmost-entry semantics here would mean a deployment
    # that ever does fall through to this branch resolves the head of a
    # client-supplied `X-Forwarded-For`, the exact divergence between the two
    # paths that issue #96 was about.
    trust_private_clients? = trust_private_clients?()

    connecting_ip =
      conn |> first_req_header("cf-connecting-ip") |> usable_forwarded_ip(trust_private_clients?)

    real_ip = conn |> first_req_header("x-real-ip") |> usable_forwarded_ip(trust_private_clients?)

    forwarded_for =
      conn |> first_req_header("x-forwarded-for") |> rightmost_usable_hop(trust_private_clients?)

    case connecting_ip || real_ip || forwarded_for do
      nil -> :error
      ip -> {:ok, ip}
    end
  end

  defp first_req_header(conn, name) do
    case Conn.get_req_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
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
  #
  # `:trust_private_client_ips` deliberately does not move this line. It answers
  # "may a private *forwarded* address name a visitor?", whereas this one answers
  # "may this peer speak for someone else?"; trusting a public peer's headers
  # would let any visitor forge their own rate-limit key.
  defp get_forwarded_from_socket(socket, trust_private_clients?) do
    peer_address =
      case LiveView.get_connect_info(socket, :peer_data) do
        %{address: addr} -> addr
        _other -> nil
      end

    if trusted_peer?(peer_address) do
      case LiveView.get_connect_info(socket, :x_headers) do
        headers when is_list(headers) ->
          extract_forwarded_ip_from_tuples(headers, trust_private_clients?)

        _other ->
          # Fallback to connect_params (client-supplied headers); only reached
          # when connect_info is unavailable (e.g. embed socket without session).
          get_forwarded_from_connect_params(socket, trust_private_clients?)
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

  defp get_forwarded_from_connect_params(socket, trust_private_clients?) do
    with %{} = connect_params <- LiveView.get_connect_params(socket),
         headers when is_map(headers) <- Map.get(connect_params, "headers", %{}),
         ip when is_binary(ip) <- extract_forwarded_ip_from_map(headers, trust_private_clients?) do
      ip
    else
      _other -> "unknown"
    end
  end

  defp extract_forwarded_ip_from_tuples(headers, trust_private_clients?) do
    # Headers are [{name, value}, ...] tuples from :x_headers connect_info, in
    # the order the request carried them. Phoenix's :x_headers collects only
    # headers whose name starts with "x-", so CF-Connecting-IP (no "x-" prefix)
    # is never present on the socket path. Only called when the direct peer is
    # a trusted private/loopback address (see get_forwarded_from_socket/1).
    #
    # Mirrors `RemoteIp`: the entries of both headers are concatenated in
    # header order and the rightmost usable one wins, so x-real-ip does not
    # outrank x-forwarded-for (see the moduledoc).
    headers
    |> Enum.flat_map(fn
      {name, value} when name in @forwarded_headers and is_binary(value) -> [value]
      _other -> []
    end)
    |> Enum.join(",")
    |> rightmost_usable_hop(trust_private_clients?)
    |> Kernel.||("unknown")
  end

  # A forwarded header may only name a *client*, never another hop.
  #
  # `trusted_peer?/1` already draws that line for the socket's direct peer, and
  # the same line applies here: an address in one of those ranges is a proxy
  # talking about itself, not a visitor. Accepting one collapses every IP-keyed
  # rate limit into a single bucket shared by the whole deployment, which is
  # how a two-tier proxy (`proxy_set_header X-Real-IP $remote_addr` on the
  # inner hop) locked one self-hoster out of their own booking page — the
  # limiter kept refusing bookings keyed on `192.168.1.254` (issue #96).
  #
  # This matches `Plug.RemoteIp`, which skips reserved blocks on the conn path;
  # before this the two paths disagreed, and only the socket path was wrong.
  #
  # A deployment whose visitors genuinely are on a private network (an
  # intranet-only self-host) is the case this gets wrong, and it resolves every
  # visitor to the proxy's LAN address. `:trust_private_client_ips` is the
  # opt-out for exactly that shape; see `trust_private_clients?/0`.
  #
  # That opt-out only restores per-visitor limits when the reverse proxy
  # directly in front of the app is the only hop between it and the visitor.
  # With a further private proxy tier upstream of that one (e.g. a LAN proxy
  # in front of an inner nginx), the flag cannot tell the outer hop apart from
  # a visitor either, and everyone behind it still collapses onto the outer
  # proxy's address.
  defp usable_forwarded_ip(nil, _trust_private_clients?), do: nil

  defp usable_forwarded_ip(value, trust_private_clients?) when is_binary(value) do
    candidate = value |> String.trim() |> strip_port()

    case :inet.parse_address(String.to_charlist(candidate)) do
      {:ok, address} -> if proxy_hop?(address, trust_private_clients?), do: nil, else: candidate
      {:error, :einval} -> nil
    end
  end

  # Does this forwarded address name a hop rather than a visitor?
  #
  # With `:trust_private_client_ips` enabled nothing is treated as a hop and the
  # rightmost entry wins, which is precisely what `remote_ip_clients/0` does on
  # the conn path: `RemoteIp.type/2` consults `clients:` before its hardcoded
  # `@reserved` list, and its own `client_from/2` walks the list from the right.
  # The two paths therefore stay in agreement in both states of the flag.
  defp proxy_hop?(_address, true), do: false
  defp proxy_hop?(address, false), do: trusted_peer?(address)

  # Whether forwarded addresses in loopback/RFC-1918/4193 ranges name visitors.
  #
  # `false` everywhere by default, which is the behaviour every internet-facing
  # deployment needs: an address in one of those ranges is a proxy talking about
  # itself. An operator whose visitors genuinely sit on the LAN sets
  # `TRUST_PRIVATE_CLIENT_IPS=true`, which `config/runtime.exs` turns into this
  # key. The socket path reads it here and the conn path through
  # `remote_ip_clients/0`, so the two cannot be configured apart.
  defp trust_private_clients? do
    Application.get_env(:tymeslot, :trust_private_client_ips, false)
  end

  # Some proxies write the source port into the header: `[2001:db8::1]:8080`
  # for IPv6, `203.0.113.9:1234` for IPv4. It has to come off before the value
  # is used. The port is fresh on every connection, so leaving it in gives each
  # request from one client its own rate-limit bucket and the limit never fires
  # for that client at all.
  defp strip_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [address, _port] -> address
      _unbracketed -> rest
    end
  end

  defp strip_port(value) do
    # Exactly one colon means IPv4 with a port; a bare IPv6 address has several
    # and must be left alone.
    case String.split(value, ":") do
      [address, _port] -> address
      _not_ipv4_with_port -> value
    end
  end

  # The rightmost usable entry, not the leftmost.
  #
  # Each hop appends the address it received the request from, so the tail is
  # written by our own infrastructure and the head by whoever spoke first — a
  # client that sends its own `X-Forwarded-For: 1.2.3.4` header puts that value
  # at the head. Walking from the right and stopping at the first non-hop
  # address therefore yields the real client and cannot be steered by one.
  defp rightmost_usable_hop(nil, _trust_private_clients?), do: nil

  defp rightmost_usable_hop(value, trust_private_clients?) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.reverse()
    |> Enum.find_value(&usable_forwarded_ip(&1, trust_private_clients?))
  end

  defp extract_forwarded_ip_from_map(headers, trust_private_clients?) do
    # Check for various header formats (headers might be lowercase). A map
    # carries no header order, so x-forwarded-for is consulted before x-real-ip,
    # the order `RemoteIp` lands on when a proxy appends both. Same hop
    # filtering as extract_forwarded_ip_from_tuples/2.
    connecting_ip =
      headers |> Map.get("cf-connecting-ip") |> usable_forwarded_ip(trust_private_clients?)

    real_ip = headers |> Map.get("x-real-ip") |> usable_forwarded_ip(trust_private_clients?)

    forwarded_for =
      headers |> Map.get("x-forwarded-for") |> rightmost_usable_hop(trust_private_clients?)

    connecting_ip || forwarded_for || real_ip
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
