defmodule TymeslotWeb.Plugs.ExtraStaticTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :plugs

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  @fixture_dir Path.expand("../../support/fixtures/extra_static", __DIR__)

  test "serves nothing when no extra sources are configured", %{conn: conn} do
    # Pinned explicitly: when the suite runs under a downstream overlay, that
    # overlay's config sets this key, so the default cannot be relied upon here.
    setup_config(:tymeslot, :extra_static_sources, [])

    # Unserved paths fall through to the /:username catch-all, which raises a
    # real 404 for the unknown organizer "extra-fixture".
    assert_error_sent(404, fn -> get(conn, "/extra-fixture/hello.txt") end)
  end

  test "serves files from a configured source", %{conn: conn} do
    setup_config(:tymeslot, :extra_static_sources, [
      [at: "/", from: @fixture_dir, only: ["extra-fixture"]]
    ])

    conn = get(conn, "/extra-fixture/hello.txt")

    assert conn.status == 200
    assert conn.resp_body =~ "hello from an extra static source"
    assert hd(get_resp_header(conn, "content-type")) =~ "text/plain"
  end

  test "does not serve paths outside the only allowlist", %{conn: conn} do
    setup_config(:tymeslot, :extra_static_sources, [
      [at: "/", from: @fixture_dir, only: ["something-else"]]
    ])

    # The path is outside the allowlist, so it falls through to the /:username
    # catch-all, which raises a real 404 for the unknown organizer.
    assert_error_sent(404, fn -> get(conn, "/extra-fixture/hello.txt") end)
  end

  test "falls through to later sources in the list", %{conn: conn} do
    setup_config(:tymeslot, :extra_static_sources, [
      [at: "/", from: @fixture_dir, only: ["not-here"]],
      [at: "/", from: @fixture_dir, only: ["extra-fixture"]]
    ])

    conn = get(conn, "/extra-fixture/hello.txt")

    assert conn.status == 200
  end

  describe "content-encoding negotiation" do
    # Mirrors the production encodings list built in the overlay's config;
    # test env deliberately leaves encodings off elsewhere, so the matrix is
    # exercised here against pre-built .zst/.gz fixture siblings.
    setup do
      setup_config(:tymeslot, :extra_static_sources, [
        [
          at: "/",
          from: @fixture_dir,
          only: ["extra-fixture"],
          encodings: [{"zstd", ".zst"}, {"gzip", ".gz"}]
        ]
      ])

      :ok
    end

    test "serves the zstd variant to a client accepting zstd", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept-encoding", "zstd, gzip")
        |> get("/extra-fixture/hello.txt")

      assert conn.status == 200
      assert get_resp_header(conn, "content-encoding") == ["zstd"]
      assert "Accept-Encoding" in get_resp_header(conn, "vary")
      assert conn.resp_body == File.read!("#{@fixture_dir}/extra-fixture/hello.txt.zst")
    end

    test "serves the gzip variant to a client without zstd support", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept-encoding", "gzip")
        |> get("/extra-fixture/hello.txt")

      assert conn.status == 200
      assert get_resp_header(conn, "content-encoding") == ["gzip"]
      assert conn.resp_body == File.read!("#{@fixture_dir}/extra-fixture/hello.txt.gz")
    end

    test "serves the plain file when the client sends no accept-encoding", %{conn: conn} do
      conn = get(conn, "/extra-fixture/hello.txt")

      assert conn.status == 200
      assert get_resp_header(conn, "content-encoding") == []
      assert "Accept-Encoding" in get_resp_header(conn, "vary")
      assert conn.resp_body =~ "hello from an extra static source"
    end

    test "falls back to gzip when the zstd sibling is missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept-encoding", "zstd, gzip")
        |> get("/extra-fixture/gzip-only.txt")

      assert conn.status == 200
      assert get_resp_header(conn, "content-encoding") == ["gzip"]
    end

    test "serves the plain file when no accepted sibling exists", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept-encoding", "zstd")
        |> get("/extra-fixture/gzip-only.txt")

      assert conn.status == 200
      assert get_resp_header(conn, "content-encoding") == []
      assert conn.resp_body =~ "gzip-only fixture body"
    end
  end

  test "skips a source naming an absent application without crashing", %{conn: conn} do
    setup_config(:tymeslot, :extra_static_sources, [
      [at: "/", from: {:no_such_app_xyz, "priv/static"}, only: ["extra-fixture"]],
      [at: "/", from: @fixture_dir, only: ["extra-fixture"]]
    ])

    {conn, log} =
      with_log(fn -> get(conn, "/extra-fixture/hello.txt") end)

    assert conn.status == 200
    assert log =~ "skipping invalid static source"
  end
end
