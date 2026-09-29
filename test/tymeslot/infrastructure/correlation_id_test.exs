defmodule Tymeslot.Infrastructure.CorrelationIdTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Phoenix.LiveView.Socket
  alias Plug.Conn
  alias Plug.RequestId
  alias Plug.Test, as: PlugTest
  alias Tymeslot.Infrastructure.CorrelationId

  @uuid_v4 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  describe "generate/0" do
    test "returns a UUID v4 format string" do
      id = CorrelationId.generate()

      assert id =~ @uuid_v4
    end

    test "generates unique IDs" do
      ids = for _i <- 1..100, do: CorrelationId.generate()

      assert length(Enum.uniq(ids)) == 100
    end
  end

  describe "Conn helpers" do
    test "put_in_conn/2 sets assigns and response header" do
      conn = PlugTest.conn(:get, "/")
      id = CorrelationId.generate()

      updated = CorrelationId.put_in_conn(conn, id)

      assert updated.assigns[:correlation_id] == id
      assert Conn.get_resp_header(updated, "x-correlation-id") == [id]
    end

    test "get_from_conn/1 reads the id the plug settled on" do
      id = CorrelationId.generate()

      conn = Conn.assign(PlugTest.conn(:get, "/"), :correlation_id, id)

      assert CorrelationId.get_from_conn(conn) == id
    end

    test "get_from_conn/1 does not trust the raw request header" do
      conn = Conn.put_req_header(PlugTest.conn(:get, "/"), "x-correlation-id", "not validated")

      assert CorrelationId.get_from_conn(conn) == nil
    end
  end

  describe "valid?/1" do
    test "accepts 8 to 128 characters of letters, digits, underscores and hyphens" do
      assert CorrelationId.valid?("abcd-1_Z")
      assert CorrelationId.valid?(String.duplicate("a", 128))
      assert CorrelationId.valid?(CorrelationId.generate())
      assert CorrelationId.valid?(RequestId.generate())
    end

    test "rejects ids that are too short, too long, or carry other characters" do
      refute CorrelationId.valid?("abc-123")
      refute CorrelationId.valid?(String.duplicate("a", 129))
      refute CorrelationId.valid?("abcdefgh\n")
      refute CorrelationId.valid?("abcd efgh")
      refute CorrelationId.valid?("abcd<efgh>")
      refute CorrelationId.valid?(nil)
    end
  end

  describe "Socket helpers" do
    test "put_in_socket/2 and get_from_socket/1 round-trip" do
      socket = %Socket{}
      id = CorrelationId.generate()

      updated = CorrelationId.put_in_socket(socket, id)

      assert CorrelationId.get_from_socket(updated) == id
    end

    test "get_from_socket/1 returns nil when absent" do
      socket = %Socket{}

      assert CorrelationId.get_from_socket(socket) == nil
    end
  end

  describe "process dictionary" do
    test "put_in_process/1 and get_from_process/0 round-trip" do
      id = CorrelationId.generate()

      CorrelationId.put_in_process(id)

      assert CorrelationId.get_from_process() == id
    end

    test "get_from_process/0 returns nil when unset" do
      result = Task.await(Task.async(fn -> CorrelationId.get_from_process() end))

      assert result == nil
    end
  end

  describe "ensure/1 with Socket" do
    test "generates new ID when missing" do
      socket = %Socket{}

      {updated_socket, id} = CorrelationId.ensure(socket)

      assert id =~ @uuid_v4
      assert CorrelationId.get_from_socket(updated_socket) == id
    end

    test "preserves existing ID from assigns" do
      existing_id = CorrelationId.generate()

      socket = CorrelationId.put_in_socket(%Socket{}, existing_id)

      {_updated_socket, id} = CorrelationId.ensure(socket)

      assert id == existing_id
    end
  end

  describe "Plug behaviour" do
    test "with no inbound headers the correlation id is the request id" do
      conn = run_plugs(PlugTest.conn(:get, "/"))

      [request_id] = Conn.get_resp_header(conn, "x-request-id")

      assert conn.assigns[:correlation_id] == request_id
      assert Conn.get_resp_header(conn, "x-correlation-id") == [request_id]
      assert Logger.metadata()[:correlation_id] == request_id
      assert Logger.metadata()[:request_id] == request_id
      assert CorrelationId.get_from_process() == request_id

      assert %{"correlation_id" => ^request_id, "request_id" => ^request_id} =
               ErrorTracker.get_context()
    end

    test "a valid inbound x-correlation-id is honoured and echoed" do
      inbound = "upstream-trace_0042"

      conn =
        PlugTest.conn(:get, "/")
        |> Conn.put_req_header("x-correlation-id", inbound)
        |> run_plugs()

      [request_id] = Conn.get_resp_header(conn, "x-request-id")

      assert request_id != inbound
      assert conn.assigns[:correlation_id] == inbound
      assert Conn.get_resp_header(conn, "x-correlation-id") == [inbound]
      assert Logger.metadata()[:correlation_id] == inbound
      assert Logger.metadata()[:request_id] == request_id

      assert %{"correlation_id" => ^inbound, "request_id" => ^request_id} =
               ErrorTracker.get_context()
    end

    test "a valid inbound x-request-id becomes the correlation id too" do
      inbound = "upstream-request-id-0000042"

      conn =
        PlugTest.conn(:get, "/")
        |> Conn.put_req_header("x-request-id", inbound)
        |> run_plugs()

      assert Conn.get_resp_header(conn, "x-request-id") == [inbound]
      assert conn.assigns[:correlation_id] == inbound
      assert Conn.get_resp_header(conn, "x-correlation-id") == [inbound]
    end

    for {label, bad_id} <- [
          {"10 KB long", String.duplicate("a", 10_240)},
          {"containing a newline", "abcdefgh\nforged: log-line"},
          {"containing disallowed characters", "<script>alert(1)</script>"}
        ] do
      test "an inbound x-correlation-id #{label} is ignored and not echoed" do
        bad_id = unquote(bad_id)

        conn =
          PlugTest.conn(:get, "/")
          |> Conn.put_req_header("x-correlation-id", bad_id)
          |> run_plugs()

        [request_id] = Conn.get_resp_header(conn, "x-request-id")

        assert conn.assigns[:correlation_id] == request_id
        assert Conn.get_resp_header(conn, "x-correlation-id") == [request_id]
        assert Logger.metadata()[:correlation_id] == request_id
        assert %{"correlation_id" => ^request_id} = ErrorTracker.get_context()
      end
    end

    test "an inbound x-request-id that Plug.RequestId accepts but the format rejects is replaced" do
      # Plug.RequestId only checks the length (20 to 200 bytes), so a value
      # like this one reaches the response header and Logger metadata as is.
      bad_request_id = "<img src=x onerror=alert(1)>"

      conn =
        PlugTest.conn(:get, "/")
        |> Conn.put_req_header("x-request-id", bad_request_id)
        |> run_plugs()

      [request_id] = Conn.get_resp_header(conn, "x-request-id")

      assert request_id != bad_request_id
      assert CorrelationId.valid?(request_id)
      assert conn.assigns[:correlation_id] == request_id
      assert Logger.metadata()[:request_id] == request_id
      assert Logger.metadata()[:correlation_id] == request_id
    end
  end

  defp run_plugs(conn) do
    conn
    |> RequestId.call(RequestId.init([]))
    |> CorrelationId.call(CorrelationId.init([]))
  end
end
