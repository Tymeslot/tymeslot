defmodule TymeslotWeb.FreebusyControllerTest do
  # async: false — the rate-limit test relies on the shared Hammer ETS bucket,
  # which other async tests clear via RateLimiter's test-only reset. Matches the
  # convention of the other rate-limited controller tests (session, guest_rsvp).
  use TymeslotWeb.ConnCase, async: false

  @moduletag :controllers

  import Tymeslot.Factory

  alias Tymeslot.FreeBusy
  alias Tymeslot.Security.RateLimiter

  describe "GET /free-busy/:token" do
    test "returns a text/calendar VFREEBUSY for a valid token", %{conn: conn} do
      {:ok, profile} = FreeBusy.enable_feed(insert(:profile))

      conn = get(conn, ~p"/free-busy/#{profile.freebusy_token}")

      assert conn |> get_resp_header("content-type") |> List.first() =~ "text/calendar"
      body = response(conn, 200)
      assert body =~ "BEGIN:VCALENDAR"
      assert body =~ "BEGIN:VFREEBUSY"
    end

    test "returns 404 for an unknown token", %{conn: conn} do
      conn = get(conn, ~p"/free-busy/does-not-exist")

      assert response(conn, 404)
    end

    test "returns 429 when the per-IP rate limit is exceeded", %{conn: conn} do
      # Pin a dedicated remote IP so the bucket is isolated from the other
      # tests in this file (which use the default 127.0.0.1). `Plug.RemoteIp`
      # leaves an explicitly-set `remote_ip` untouched when no trusted
      # forwarded headers are present, so `ClientIP.get/1` resolves to exactly
      # this address — matching the bucket we pre-fill here.
      rate_limit_ip = {203, 0, 113, 7}
      bucket_key = "freebusy:203.0.113.7"
      for _i <- 1..60, do: RateLimiter.check_rate(bucket_key, 60_000, 60)

      conn = get(%{conn | remote_ip: rate_limit_ip}, ~p"/free-busy/any-token")

      assert response(conn, 429)
    end
  end
end
