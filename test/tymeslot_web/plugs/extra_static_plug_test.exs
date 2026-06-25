defmodule TymeslotWeb.Plugs.ExtraStaticTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :plugs

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  @fixture_dir Path.expand("../../support/fixtures/extra_static", __DIR__)

  test "serves nothing when no extra sources are configured", %{conn: conn} do
    # Pinned explicitly: when the suite runs from the umbrella root, the SaaS
    # config sets this key, so the default cannot be relied upon here.
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
