defmodule Tymeslot.Infrastructure.ProxySocketOptionsTest do
  @moduledoc """
  Drives real sockets through the options `ProxyConfig` emits, because asserting
  on the option list alone cannot catch this class of bug.

  The proxy tuple's socket options have to differ by target scheme, and the two
  requirements are exact opposites (see `ProxyConfig.build_req_proxy_options/2`).
  1.15.3 shipped `mode: :passive` for both, which fixed proxied `http://` and
  broke every proxied `https://` request with a 30s `{:proxy, :tunnel_timeout}`
  (issue #97). The unit tests of the day stayed green throughout: they asserted
  the literal the code produced, so they moved with it.

  These tests observe the outcome instead. A stub proxy on loopback reports what
  it received, so a wrong option list shows up as a tunnel that never carries
  bytes, or a response Finch's `recv/3` cannot read — the two failures operators
  actually hit.
  """
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Mint.HTTP, as: MintHTTP
  alias Tymeslot.Infrastructure.{ProxyConfig, ProxyCredentials}

  setup do
    # These tests open the first real TLS socket in some runs, and :ssl is
    # started by whichever test happens to reach the network first. Don't
    # inherit that ordering.
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    :ok
  end

  # A TLS record: content type 0x16 (handshake), version 0x03xx. Mint writes one
  # of these into the tunnel as soon as CONNECT has been answered, so its arrival
  # at the proxy is proof that the handshake completed and the socket is live.
  @tls_client_hello_prefix 0x16

  # Generous on purpose. The assertions are about *whether* bytes cross the
  # tunnel, never how fast: the TLS upgrade runs in a task competing with the
  # whole async suite for a scheduler, and a tight bound here would report a
  # busy machine as a proxy regression.
  @stub_timeout 30_000

  describe "proxied https:// requests" do
    test "the CONNECT tunnel is established and carries the TLS handshake" do
      port = start_stub_proxy()

      connect_options =
        ProxyConfig.build_req_proxy_options(
          proxy_config(port),
          "https://calendar.example.com/dav/user/Calendar/"
        )
        |> Keyword.fetch!(:connect_options)
        # Finch opens its connections in passive mode. It belongs on the *host*
        # options, where Mint rebuilds the connection after the tunnel upgrade —
        # never on the proxy tuple, which is the socket CONNECT is spoken over.
        |> Keyword.merge(mode: :passive)

      connect =
        Task.async(fn ->
          MintHTTP.connect(:https, "calendar.example.com", 443, connect_options)
        end)

      assert_receive {:proxy_request_line, "CONNECT calendar.example.com:443 HTTP/1.1"},
                     @stub_timeout

      assert_receive {:tunnel_payload, <<@tls_client_hello_prefix, 0x03, _rest::binary>>},
                     @stub_timeout

      Task.shutdown(connect, :brutal_kill)
    end

    test "the proxy tuple never asks for passive mode, which would silence CONNECT" do
      options =
        ProxyConfig.build_req_proxy_options(
          proxy_config(3128),
          "https://calendar.example.com/dav/"
        )

      {_scheme, _host, _port, socket_options} = options[:connect_options][:proxy]

      refute Keyword.has_key?(socket_options, :mode),
             "Mint.TunnelProxy receives the CONNECT reply as socket messages, so this " <>
               "socket must stay in Mint's default active mode. See issue #97."
    end

    test "a stalled CONNECT is bounded by our own budget, not Mint's 30s default" do
      options =
        ProxyConfig.build_req_proxy_options(
          proxy_config(3128),
          "https://calendar.example.com/dav/"
        )

      {_scheme, _host, _port, socket_options} = options[:connect_options][:proxy]

      assert socket_options[:tunnel_timeout] == options[:connect_options][:timeout]
    end
  end

  describe "proxied http:// requests" do
    test "the response can be read by the passive recv/3 Finch uses" do
      port = start_stub_proxy()

      connect_options =
        ProxyConfig.build_req_proxy_options(
          proxy_config(port),
          "http://calendar.example.com/dav/user/Calendar/"
        )
        |> Keyword.fetch!(:connect_options)
        |> Keyword.merge(mode: :passive)

      {:ok, conn} = MintHTTP.connect(:http, "calendar.example.com", 80, connect_options)
      {:ok, conn, ref} = MintHTTP.request(conn, "GET", "/dav/user/Calendar/", [], nil)

      # Raises ArgumentError ("can't use recv/3 … when the mode is :active") if
      # the proxy tuple stops carrying mode: :passive on this path.
      {:ok, _conn, responses} = MintHTTP.recv(conn, 0, @stub_timeout)

      assert_receive {:proxy_request_line,
                      "GET http://calendar.example.com/dav/user/Calendar/ HTTP/1.1"},
                     @stub_timeout

      assert Enum.member?(responses, {:status, ref, 200})
      assert Enum.member?(responses, {:data, ref, "hello"})
    end

    test "the proxy tuple asks for passive mode, which Mint 1.10.0 reads nowhere else" do
      options =
        ProxyConfig.build_req_proxy_options(
          proxy_config(3128),
          "http://calendar.example.com/dav/"
        )

      {_scheme, _host, _port, socket_options} = options[:connect_options][:proxy]

      assert socket_options[:mode] == :passive
    end
  end

  describe "proxy authentication" do
    test "the Proxy-Authorization header reaches the proxy on the CONNECT request" do
      port = start_stub_proxy()

      connect_options =
        ProxyConfig.build_req_proxy_options(
          %{proxy_config(port) | auth: ProxyCredentials.new({"dav-user", "s3cret"})},
          "https://calendar.example.com/dav/"
        )
        |> Keyword.fetch!(:connect_options)
        |> Keyword.merge(mode: :passive)

      connect =
        Task.async(fn ->
          MintHTTP.connect(:https, "calendar.example.com", 443, connect_options)
        end)

      assert_receive {:proxy_request_headers, headers}, @stub_timeout

      expected = "Basic " <> Base.encode64("dav-user:s3cret")
      assert headers["proxy-authorization"] == expected

      Task.shutdown(connect, :brutal_kill)
    end
  end

  defp proxy_config(port) do
    %{host: "127.0.0.1", port: port, auth: nil, scheme: "http"}
  end

  # A forward proxy that answers on loopback and reports to the test process
  # what it was actually sent. It never relays anywhere: the point is what
  # arrives, not what comes back.
  defp start_stub_proxy do
    test_pid = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen_socket)
    acceptor = spawn(fn -> accept_loop(listen_socket, test_pid) end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen_socket)
    end)

    port
  end

  defp accept_loop(listen_socket, test_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        # The serving task must not touch the socket before it owns it, or its
        # first recv/3 returns {:error, :not_owner} and the connection dies with
        # nothing reported. Hand over, then release it.
        {:ok, pid} = Task.start(fn -> await_ownership(socket, test_pid) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :owned)
        accept_loop(listen_socket, test_pid)

      {:error, :closed} ->
        :ok
    end
  end

  defp await_ownership(socket, test_pid) do
    receive do
      :owned -> serve(socket, test_pid)
    after
      @stub_timeout -> :gen_tcp.close(socket)
    end
  end

  # Names lowercased, values left exactly as sent — the credential is one of them.
  defp parse_headers(header_lines) do
    header_lines
    |> Enum.flat_map(fn line ->
      case String.split(line, ": ", parts: 2) do
        [name, value] -> [{String.downcase(name), value}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp serve(socket, test_pid) do
    {:ok, request} = :gen_tcp.recv(socket, 0, @stub_timeout)
    [request_line | header_lines] = String.split(request, "\r\n")

    send(test_pid, {:proxy_request_line, request_line})
    send(test_pid, {:proxy_request_headers, parse_headers(header_lines)})

    if String.starts_with?(request_line, "CONNECT ") do
      :gen_tcp.send(socket, "HTTP/1.1 200 Connection established\r\n\r\n")

      # Anything from here on arrived through the tunnel rather than the
      # CONNECT exchange, which is exactly what the regression prevents.
      case :gen_tcp.recv(socket, 0, @stub_timeout) do
        {:ok, payload} -> send(test_pid, {:tunnel_payload, payload})
        {:error, reason} -> send(test_pid, {:tunnel_error, reason})
      end
    else
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello")
      :gen_tcp.recv(socket, 0, @stub_timeout)
    end

    :gen_tcp.close(socket)
  end
end
