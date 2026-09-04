defmodule Tymeslot.Infrastructure.HTTPClientProxyPinningTest do
  @moduledoc """
  A self-hoster behind an egress proxy exempts their internal hosts from it
  with `NO_PROXY`. Connection pinning rewrites a guarded request's host to the
  IP literal the SSRF check approved, and a `NO_PROXY` entry naming
  `internal.example.com` cannot match `127.0.0.1`: evaluate the proxy decision
  after that rewrite and the bypass silently stops working, sending internal
  traffic through a proxy that may well not be able to reach it.

  Both halves run against real sockets, because that is the only place the
  answer is visible. A Bandit server stands in for the destination and a raw
  TCP listener for the proxy, the latter reporting the request line it was
  handed — a proxied request names its destination there, so the line says
  both that the proxy was used and which host it was asked for. The suite's
  usual Req test plug opens no socket and is deliberately never pinned, so it
  is cleared here.
  """
  use ExUnit.Case, async: false

  @moduletag :infrastructure
  @moduletag :security

  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Tymeslot.Infrastructure.HTTPClient

  defmodule DestinationPlug do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      host =
        case Conn.get_req_header(conn, "host") do
          [host | _rest] -> host
          [] -> "(none)"
        end

      send(Keyword.fetch!(opts, :test_pid), {:destination_host, host})

      Conn.send_resp(conn, 200, "destination")
    end
  end

  defmodule LoopbackResolver do
    @moduledoc false
    @behaviour Tymeslot.Security.DnsResolutionBehaviour

    @impl Tymeslot.Security.DnsResolutionBehaviour
    def check_private_ip(_url, _opts), do: :ok

    @impl Tymeslot.Security.DnsResolutionBehaviour
    def resolve_public(_url, _opts), do: {:ok, [{127, 0, 0, 1}]}
  end

  setup do
    # The guard resolves only in :prod and only while the private-IP opt-out is
    # off; the stub resolver is what makes a loopback destination approvable,
    # and its address is the one the request must end up pinned to.
    setup_config(:tymeslot, :environment, :prod)
    setup_config(:tymeslot, :allow_private_ips_for_calendar, false)
    setup_config(:tymeslot, :dns_resolver_module, LoopbackResolver)
    setup_config(:tymeslot, :req_test_plug, nil)

    {:ok, destination_port: start_destination(), proxy_port: start_proxy_stub()}
  end

  describe "a guarded request whose host NO_PROXY exempts" do
    test "goes direct, pinned to the approved address", context do
      configure_proxy(context.proxy_port, ["internal.example.com"])

      assert {:ok, %Req.Response{status: 200, body: "destination"}} =
               guarded_get(context.destination_port)

      # Nothing but the destination server answers on that port, so the socket
      # was opened to 127.0.0.1; the Host header still names what the operator
      # typed. That pair is what pinning means.
      assert_received {:destination_host, host}
      assert host == "internal.example.com:#{context.destination_port}"

      refute_received {:proxy_request_line, _line}
    end

    test "and a wildcard NO_PROXY entry exempts it just the same", context do
      configure_proxy(context.proxy_port, ["*.example.com"])

      assert {:ok, %Req.Response{status: 200, body: "destination"}} =
               guarded_get(context.destination_port)

      assert_received {:destination_host, _host}
      refute_received {:proxy_request_line, _line}
    end
  end

  describe "a guarded request NO_PROXY does not exempt" do
    test "goes through the proxy, unpinned and under its own hostname", context do
      configure_proxy(context.proxy_port, ["other.example.com"])

      assert {:ok, %Req.Response{status: 200, body: "proxy"}} =
               guarded_get(context.destination_port)

      # A proxy resolves the destination itself, so it has to be asked for the
      # hostname. Handing it the pinned IP literal would defeat nothing here
      # but would be the wrong request to make of it.
      assert_received {:proxy_request_line, line}
      assert line =~ "internal.example.com:#{context.destination_port}"
      refute line =~ "127.0.0.1"

      refute_received {:destination_host, _host}
    end
  end

  defp guarded_get(destination_port) do
    HTTPClient.get("http://internal.example.com:#{destination_port}/echo", [],
      ssrf_protect: true,
      receive_timeout: 2_000
    )
  end

  defp configure_proxy(proxy_port, no_proxy) do
    with_config(:tymeslot, :http_proxy, %{
      http_proxy: %{host: "127.0.0.1", port: proxy_port, auth: nil, scheme: "http"},
      https_proxy: nil,
      no_proxy: no_proxy
    })
  end

  defp start_destination do
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: {DestinationPlug, test_pid: self()}, scheme: :http, ip: {127, 0, 0, 1}, port: port}
    )

    port
  end

  # Deliberately not an HTTP server: an HTTP-forwarded request carries its
  # destination in the request line (`GET http://host:port/path HTTP/1.1`), and
  # a Plug adapter has already normalised that away by the time a plug runs.
  defp start_proxy_stub do
    test_pid = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        reuseaddr: true,
        packet: :line
      ])

    {:ok, port} = :inet.port(listen_socket)
    {:ok, _acceptor} = Task.start_link(fn -> accept_loop(listen_socket, test_pid) end)
    on_exit(fn -> :gen_tcp.close(listen_socket) end)

    port
  end

  defp accept_loop(listen_socket, test_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        report_request_line(socket, test_pid)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-length: 5\r\nconnection: close\r\n\r\nproxy"
        )

        :gen_tcp.close(socket)
        accept_loop(listen_socket, test_pid)

      {:error, _closed} ->
        :ok
    end
  end

  defp report_request_line(socket, test_pid) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, line} -> send(test_pid, {:proxy_request_line, String.trim(line)})
      {:error, _reason} -> :ok
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
