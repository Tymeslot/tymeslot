defmodule Tymeslot.Infrastructure.CorrelationIdTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Phoenix.LiveView.Socket
  alias Plug.Conn
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

    test "get_from_conn/1 reads from request header first" do
      id = CorrelationId.generate()

      conn = Conn.put_req_header(PlugTest.conn(:get, "/"), "x-correlation-id", id)

      assert CorrelationId.get_from_conn(conn) == id
    end

    test "get_from_conn/1 falls back to assigns" do
      id = CorrelationId.generate()

      conn = Conn.assign(PlugTest.conn(:get, "/"), :correlation_id, id)

      assert CorrelationId.get_from_conn(conn) == id
    end

    test "get_from_conn/1 returns nil when absent" do
      conn = PlugTest.conn(:get, "/")

      assert CorrelationId.get_from_conn(conn) == nil
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

  describe "ensure/1 with Conn" do
    test "generates new ID when missing" do
      conn = PlugTest.conn(:get, "/")

      {updated_conn, id} = CorrelationId.ensure(conn)

      assert id =~ @uuid_v4
      assert updated_conn.assigns[:correlation_id] == id
      assert Conn.get_resp_header(updated_conn, "x-correlation-id") == [id]
    end

    test "preserves existing ID from request header" do
      existing_id = CorrelationId.generate()

      conn = Conn.put_req_header(PlugTest.conn(:get, "/"), "x-correlation-id", existing_id)

      {_updated_conn, id} = CorrelationId.ensure(conn)

      assert id == existing_id
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

  describe "add_to_logger_metadata/1" do
    test "sets :correlation_id in Logger metadata" do
      id = CorrelationId.generate()

      CorrelationId.add_to_logger_metadata(id)

      assert Logger.metadata()[:correlation_id] == id
    end
  end

  describe "with_correlation_id/2" do
    test "sets process dict and logger metadata, executes function" do
      id = CorrelationId.generate()

      result =
        Task.await(
          Task.async(fn ->
            CorrelationId.with_correlation_id(id, fn ->
              {CorrelationId.get_from_process(), Logger.metadata()[:correlation_id]}
            end)
          end)
        )

      assert result == {id, id}
    end

    test "auto-generates ID when nil" do
      result =
        Task.await(
          Task.async(fn ->
            CorrelationId.with_correlation_id(nil, fn ->
              CorrelationId.get_from_process()
            end)
          end)
        )

      assert result =~ @uuid_v4
    end

    test "returns function result" do
      assert :my_result = CorrelationId.with_correlation_id(fn -> :my_result end)
    end
  end

  describe "Plug behavior" do
    test "call/2 on a bare conn generates and sets correlation ID" do
      conn = CorrelationId.call(PlugTest.conn(:get, "/"), [])

      id = conn.assigns[:correlation_id]

      assert id =~ @uuid_v4
      assert Conn.get_resp_header(conn, "x-correlation-id") == [id]
    end

    test "call/2 preserves incoming x-correlation-id header" do
      existing_id = CorrelationId.generate()

      conn =
        PlugTest.conn(:get, "/")
        |> Conn.put_req_header("x-correlation-id", existing_id)
        |> CorrelationId.call([])

      # ensure/1 returns original conn when header exists (no assigns/resp_header set)
      # But the ID is available via get_from_conn which reads the request header
      assert CorrelationId.get_from_conn(conn) == existing_id
    end
  end
end
