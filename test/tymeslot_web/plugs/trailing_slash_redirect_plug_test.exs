defmodule TymeslotWeb.Plugs.TrailingSlashRedirectPlugTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :infrastructure

  alias TymeslotWeb.Plugs.TrailingSlashRedirectPlug

  defp run(method, path) do
    method |> build_conn(path) |> TrailingSlashRedirectPlug.call([])
  end

  describe "slashed GET and HEAD paths" do
    test "301 to the slashless path" do
      conn = run(:get, "/docs/")

      assert conn.halted
      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/docs"]
    end

    test "keeps the query string" do
      conn = run(:get, "/blog/?locale=uk&page=2")

      assert get_resp_header(conn, "location") == ["/blog?locale=uk&page=2"]
    end

    test "collapses a run of trailing slashes" do
      assert get_resp_header(run(:get, "/de/features//"), "location") == ["/de/features"]
    end

    test "redirects HEAD as well" do
      assert run(:head, "/features/").status == 301
    end
  end

  describe "requests left alone" do
    test "the root path" do
      refute run(:get, "/").halted
    end

    test "a slashless path" do
      refute run(:get, "/docs").halted
    end

    test "unsafe methods, which would lose their body" do
      refute run(:post, "/webhooks/stripe/").halted
    end

    test "a path that would redirect off-site as a protocol-relative URL" do
      refute run(:get, "//evil.example/").halted
      refute run(:get, "/\\evil.example/").halted
    end

    test "a path made only of slashes" do
      refute run(:get, "///").halted
    end
  end

  test "the endpoint redirects before routing" do
    conn = get(build_conn(), "/auth/login/")

    assert redirected_to(conn, 301) == "/auth/login"
  end
end
