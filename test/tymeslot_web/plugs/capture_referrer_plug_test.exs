defmodule TymeslotWeb.Plugs.CaptureReferrerPlugTest do
  @moduledoc false

  use TymeslotWeb.ConnCase, async: true

  @moduletag :plugs

  alias Plug.Test, as: PlugTest
  alias TymeslotWeb.Plugs.CaptureReferrerPlug

  @session_key "scheduling_referrer"

  # Builds a GET conn (host www.example.com) with a fresh test session and an
  # optional Referer header, ready to pass through the plug.
  defp build(referer, opts \\ []) do
    method = Keyword.get(opts, :method, "GET")
    host_header = Keyword.get(opts, :host_header)

    conn =
      build_conn()
      |> Map.put(:method, method)
      |> PlugTest.init_test_session(%{})

    # Plug refuses to set the special "host" header via put_req_header/3, so
    # inject it directly into req_headers to exercise the plug's port stripping.
    conn =
      if host_header,
        do: %{conn | req_headers: [{"host", host_header} | conn.req_headers]},
        else: conn

    if referer, do: put_req_header(conn, "referer", referer), else: conn
  end

  describe "init/1" do
    test "passes options through unchanged" do
      assert CaptureReferrerPlug.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2" do
    test "captures a cross-origin referrer on the initial GET" do
      conn = "https://www.google.com/search?q=tymeslot" |> build() |> CaptureReferrerPlug.call([])

      assert get_session(conn, @session_key) == "https://www.google.com/search?q=tymeslot"
    end

    test "uses first-touch semantics: an existing referrer is never overwritten" do
      conn =
        build_conn()
        |> PlugTest.init_test_session(%{@session_key => "https://original.example/"})
        |> put_req_header("referer", "https://later.example/")
        |> CaptureReferrerPlug.call([])

      assert get_session(conn, @session_key) == "https://original.example/"
    end

    test "skips a same-origin referrer" do
      conn = "https://www.example.com/x" |> build() |> CaptureReferrerPlug.call([])

      assert get_session(conn, @session_key) == nil
    end

    test "treats the referrer as same-origin even when the host header carries a port" do
      conn =
        "https://www.example.com/x"
        |> build(host_header: "www.example.com:4000")
        |> CaptureReferrerPlug.call([])

      assert get_session(conn, @session_key) == nil
    end

    test "skips when there is no Referer header" do
      conn = nil |> build() |> CaptureReferrerPlug.call([])

      assert get_session(conn, @session_key) == nil
    end

    test "skips an unparseable referrer" do
      conn = "not a url" |> build() |> CaptureReferrerPlug.call([])

      assert get_session(conn, @session_key) == nil
    end

    test "does not capture on non-GET requests" do
      conn =
        "https://www.google.com/" |> build(method: "POST") |> CaptureReferrerPlug.call([])

      assert get_session(conn, @session_key) == nil
    end
  end
end
