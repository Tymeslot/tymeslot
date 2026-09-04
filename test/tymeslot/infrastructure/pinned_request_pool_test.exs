defmodule Tymeslot.Infrastructure.PinnedRequestPoolTest do
  @moduledoc """
  The one test in the suite that takes a request carrying connection options
  through to a real socket.

  Everything else routes Req through a test plug, which never reaches Finch and
  so cannot observe which pool a request lands on — precisely the part that was
  wrong. Connection pinning gives every SSRF-guarded request the target's
  hostname as a connection option, so this is the path all of that traffic
  takes.
  """
  use ExUnit.Case, async: false

  @moduletag :infrastructure
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Tymeslot.Infrastructure.HTTPClient

  defmodule EchoHostPlug do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      host =
        case Conn.get_req_header(conn, "host") do
          [host | _rest] -> host
          [] -> "(none)"
        end

      Conn.send_resp(conn, 200, host)
    end
  end

  setup do
    # The suite normally hands Req a plug, which opens no socket at all.
    with_config(:tymeslot, :req_test_plug, nil)

    port = free_port()

    start_supervised!({Bandit, plug: EchoHostPlug, scheme: :http, ip: {127, 0, 0, 1}, port: port})

    {:ok, port: port}
  end

  test "connection options reach the socket", %{port: port} do
    assert {:ok, %Req.Response{status: 200, body: body}} =
             HTTPClient.get("http://127.0.0.1:#{port}/echo", [],
               connect_options: [hostname: "localhost"]
             )

    # The URL named an address and the connection named a host, which is the
    # shape every pinned request has: connect to the address the SSRF check
    # approved, present the name the user typed so a virtual-hosted target
    # still routes and its certificate still verifies.
    assert body == "localhost:#{port}"
  end

  test "and are served by the application's own Finch instance", %{port: port} do
    req_instances_before = req_managed_instances()

    assert {:ok, %Req.Response{status: 200}} =
             HTTPClient.get("http://127.0.0.1:#{port}/echo", [],
               connect_options: [hostname: "localhost"]
             )

    # Req starts and permanently keeps one whole Finch instance per distinct
    # set of connection options, named by an atom it derives from them. Pinning
    # supplies the destination's hostname on every guarded request, so this
    # count used to grow by one per host the application had ever reached, and
    # webhook destinations are user-supplied.
    assert req_managed_instances() == req_instances_before

    # The request went to a tagged pool on the shared instance instead.
    assert [tag] = shared_pool_tags(port)
    assert tag =~ ~r/^[0-9a-f]{32}$/
  end

  defp req_managed_instances do
    Req.FinchSupervisor
    |> DynamicSupervisor.count_children()
    |> Map.fetch!(:active)
  end

  # Finch registers each pool under `{scheme, host, port, tag}`, so this reads
  # what the request actually created rather than asking for a pool by a name
  # the test computed itself.
  defp shared_pool_tags(port) do
    Tymeslot.Finch
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&match?({:http, "127.0.0.1", ^port, _tag}, &1))
    |> Enum.map(fn {_scheme, _host, _port, tag} -> tag end)
    |> Enum.uniq()
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
