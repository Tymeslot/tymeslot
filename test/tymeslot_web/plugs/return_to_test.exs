defmodule TymeslotWeb.Plugs.ReturnToTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs
  @moduletag :auth

  alias Plug.Conn
  alias TymeslotWeb.Plugs.ReturnTo

  defp request(method, path, session \\ %{}) do
    method
    |> build_conn(path)
    |> init_test_session(session)
    |> ReturnTo.call([])
  end

  defp kept(path, at), do: %{"return_to" => %{"path" => path, "at" => at}}
  defp now, do: System.system_time(:second)

  describe "call/2" do
    test "keeps a safe page named on a GET" do
      conn = request(:get, "/auth/login?redirect_to=%2Fdashboard%2Fmeetings%3Fmeeting%3D3")

      assert {"/dashboard/meetings?meeting=3", _conn} = ReturnTo.pop(conn)
    end

    test "keeps nothing for an unsafe page" do
      conn = request(:get, "/auth/login?redirect_to=%2F%2Fevil.example")

      assert {nil, _conn} = ReturnTo.pop(conn)
    end

    # The session is a cookie; a page that would overflow it is not kept.
    test "keeps a page of up to 2048 bytes, and nothing longer" do
      longest = "/dashboard?q=" <> String.duplicate("a", 2048 - 13)
      too_long = longest <> "a"

      conn = request(:get, "/auth/login?" <> URI.encode_query(%{"redirect_to" => longest}))
      assert {^longest, _conn} = ReturnTo.pop(conn)

      conn = request(:get, "/auth/login?" <> URI.encode_query(%{"redirect_to" => too_long}))
      assert {nil, _conn} = ReturnTo.pop(conn)
      assert ReturnTo.login_path(too_long) == "/auth/login"
    end

    test "leaves a kept page alone on a plain visit, and on a POST" do
      session = kept("/dashboard/meetings", now())

      assert {"/dashboard/meetings", _conn} = ReturnTo.pop(request(:get, "/auth/login", session))

      post = request(:post, "/auth/login?redirect_to=%2Fdashboard%2Fother", session)
      assert {"/dashboard/meetings", _conn} = ReturnTo.pop(post)
    end
  end

  describe "pop/1" do
    test "removes the page it takes" do
      {_path, conn} = ReturnTo.pop(request(:get, "/", kept("/dashboard", now())))

      assert Conn.get_session(conn, "return_to") == nil
    end

    test "gives nothing for a page kept more than an hour ago" do
      conn = request(:get, "/", kept("/dashboard", now() - 3601))

      assert {nil, conn} = ReturnTo.pop(conn)
      assert Conn.get_session(conn, "return_to") == nil
    end
  end

  describe "login_path/2" do
    test "names a safe page and drops an unsafe one" do
      assert ReturnTo.login_path("/dashboard?x=1") ==
               "/auth/login?redirect_to=%2Fdashboard%3Fx%3D1"

      assert ReturnTo.login_path("https://evil.example") == "/auth/login"
      assert ReturnTo.login_path(nil, "/custom/login") == "/custom/login"
    end

    test "adds the page to a login page that carries a query of its own" do
      assert ReturnTo.login_path("/dashboard", "/auth/login?auth=login") ==
               "/auth/login?auth=login&redirect_to=%2Fdashboard"
    end
  end
end
