defmodule TymeslotWeb.Plugs.EnsureLocalAccessPlugTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true

  import Phoenix.Controller
  alias TymeslotWeb.Plugs.EnsureLocalAccessPlug

  @opts EnsureLocalAccessPlug.init([])
  @moduletag :utils

  describe "init/1" do
    test "sets default options" do
      opts = EnsureLocalAccessPlug.init([])
      assert opts[:error_view] == TymeslotWeb.ErrorHTML
      assert opts[:error_template] == :"403"
      assert opts[:allow_docker] == false
    end

    test "overrides default options" do
      opts = EnsureLocalAccessPlug.init(error_template: :"404", allow_docker: true)
      assert opts[:error_template] == :"404"
      assert opts[:allow_docker] == true
    end
  end

  describe "call/2" do
    test "allows access from IPv4 localhost", %{conn: conn} do
      conn = %{conn | remote_ip: {127, 0, 0, 1}}
      returned_conn = EnsureLocalAccessPlug.call(conn, @opts)

      assert returned_conn == conn
      refute returned_conn.halted
    end

    test "allows access from IPv6 localhost", %{conn: conn} do
      conn = %{conn | remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}
      returned_conn = EnsureLocalAccessPlug.call(conn, @opts)

      assert returned_conn == conn
      refute returned_conn.halted
    end

    test "denies access from non-local IP", %{conn: conn} do
      conn = %{conn | remote_ip: {1, 2, 3, 4}} |> fetch_query_params() |> put_format("html")
      returned_conn = EnsureLocalAccessPlug.call(conn, @opts)

      assert returned_conn.status == 403
      assert returned_conn.halted
      assert response(returned_conn, 403) =~ "Forbidden"
    end

    test "denies access from Docker networks by default", %{conn: conn} do
      docker_ips = [
        {172, 16, 0, 1},
        {10, 0, 0, 1},
        {192, 168, 0, 1}
      ]

      for ip <- docker_ips do
        conn = %{conn | remote_ip: ip} |> fetch_query_params() |> put_format("html")
        returned_conn = EnsureLocalAccessPlug.call(conn, @opts)

        assert returned_conn.status == 403
        assert returned_conn.halted
      end
    end

    test "allows access from Docker networks when enabled", %{conn: conn} do
      opts = EnsureLocalAccessPlug.init(allow_docker: true)

      docker_ips = [
        {172, 16, 0, 1},
        {172, 31, 255, 255},
        {10, 0, 0, 1},
        {192, 168, 0, 1}
      ]

      for ip <- docker_ips do
        conn = %{conn | remote_ip: ip} |> fetch_query_params() |> put_format("html")
        returned_conn = EnsureLocalAccessPlug.call(conn, opts)

        assert returned_conn == conn
        refute returned_conn.halted
      end
    end

    test "respects custom error view and template", %{conn: conn} do
      opts = EnsureLocalAccessPlug.init(error_template: :"404")
      conn = %{conn | remote_ip: {1, 2, 3, 4}} |> fetch_query_params() |> put_format("html")

      returned_conn = EnsureLocalAccessPlug.call(conn, opts)

      assert returned_conn.status == 403
      assert returned_conn.halted
      assert response(returned_conn, 403) =~ "Not Found"
    end
  end
end
