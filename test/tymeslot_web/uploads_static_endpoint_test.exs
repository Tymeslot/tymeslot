defmodule TymeslotWeb.UploadsStaticEndpointTest do
  @moduledoc """
  End-to-end regression for Task 96 — verifies the `/uploads` endpoint
  mount refuses to serve anything outside the upload-type allowlist.

  Before the `UploadStaticSecurity` plug landed, a file named
  `evil.html` dropped into the upload directory would be served by
  `Plug.Static` as same-origin HTML, giving any attacker who slipped
  past an upload validator a stored-XSS primitive.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :infrastructure

  @upload_dir Application.compile_env(:tymeslot, :upload_directory)

  setup do
    test_dir = Path.join(@upload_dir, "upload_static_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{test_dir: test_dir, url_segment: Path.basename(test_dir)}
  end

  test "refuses to serve a disguised HTML file", %{
    conn: conn,
    test_dir: test_dir,
    url_segment: segment
  } do
    File.write!(Path.join(test_dir, "evil.html"), "<script>alert(1)</script>")

    conn = get(conn, "/uploads/#{segment}/evil.html")

    assert conn.status == 404
    refute conn.resp_body =~ "<script>"
  end

  test "refuses .svg uploads (can embed script tags)", %{
    conn: conn,
    test_dir: test_dir,
    url_segment: segment
  } do
    File.write!(
      Path.join(test_dir, "logo.svg"),
      ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|
    )

    conn = get(conn, "/uploads/#{segment}/logo.svg")

    assert conn.status == 404
    refute conn.resp_body =~ "<svg"
  end

  test "serves an allowlisted image with nosniff header", %{
    conn: conn,
    test_dir: test_dir,
    url_segment: segment
  } do
    File.write!(Path.join(test_dir, "avatar.png"), <<137, 80, 78, 71, 13, 10, 26, 10>>)

    conn = get(conn, "/uploads/#{segment}/avatar.png")

    assert conn.status == 200
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end
end
