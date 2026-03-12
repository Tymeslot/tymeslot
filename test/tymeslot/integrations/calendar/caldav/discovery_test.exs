defmodule Tymeslot.Integrations.Calendar.CalDAV.DiscoveryTest do
  use Tymeslot.CalDAVCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.Discovery

  @caldav_client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: [],
    verify_ssl: true,
    provider: :caldav
  }

  # ---------------------------------------------------------------------------
  # test_connection/2
  # ---------------------------------------------------------------------------

  describe "test_connection/2" do
    test "succeeds when discovery path returns 207" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, "<D:multistatus xmlns:D=\"DAV:\"/>")
      end)

      assert {:ok, _message} = Discovery.test_connection(@caldav_client, ip_address: "127.0.0.1")
    end

    test "falls back to RFC 4791 probe when discovery path returns 404" do
      # First call: discovery path → 404
      # Second call: RFC 4791 probe to / → 207
      stub_sequential(
        fn conn -> Conn.send_resp(conn, 404, "") end,
        fn conn ->
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, """
          <D:multistatus xmlns:D="DAV:">
            <D:response>
              <D:href>/</D:href>
              <D:propstat>
                <D:prop>
                  <D:current-user-principal>
                    <D:href>/principals/users/user/</D:href>
                  </D:current-user-principal>
                </D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
              </D:propstat>
            </D:response>
          </D:multistatus>
          """)
        end
      )

      assert {:ok, _message} = Discovery.test_connection(@caldav_client, ip_address: "127.0.0.1")
    end

    test "falls back to RFC 4791 probe when discovery path returns 5xx" do
      # test_connection passes max_retries: 0, so the 500 is returned immediately
      # as :server_error and the fallback to RFC 4791 triggers on the first attempt.
      # Path-based routing ensures the RFC 4791 probe to "/" returns 207 while the
      # guessed discovery path consistently returns 500.
      ReqTest.stub(:tymeslot_http, fn conn ->
        if conn.request_path == "/" do
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, """
          <D:multistatus xmlns:D="DAV:">
            <D:response>
              <D:propstat>
                <D:prop>
                  <D:current-user-principal>
                    <D:href>/principals/users/user/</D:href>
                  </D:current-user-principal>
                </D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
              </D:propstat>
            </D:response>
          </D:multistatus>
          """)
        else
          # All guessed discovery paths return 500 — exhausts retry budget,
          # triggering the fallback to RFC 4791.
          Conn.send_resp(conn, 500, "Internal Server Error")
        end
      end)

      assert {:ok, _msg} = Discovery.test_connection(@caldav_client, ip_address: "127.0.0.1")
    end

    test "propagates :unauthorized even when RFC 4791 probe also returns 401" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "")
      end)

      assert {:error, :unauthorized} =
               Discovery.test_connection(
                 %{@caldav_client | password: "bad"},
                 ip_address: "127.0.0.1"
               )
    end
  end

  # ---------------------------------------------------------------------------
  # discover_calendars/2 — RFC 4791 discovery chain
  # ---------------------------------------------------------------------------

  describe "discover_calendars/2 RFC 4791 chain" do
    test "follows full chain when discovery path returns 404" do
      call_count = :counters.new(1, [:atomics])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        cond do
          n == 1 ->
            # Guessed discovery path → 404
            Conn.send_resp(conn, 404, "")

          n == 2 ->
            # RFC 4791 step 1: current-user-principal at server root
            assert conn.request_path == "/"

            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, """
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:propstat>
                  <D:prop>
                    <D:current-user-principal>
                      <D:href>/principals/users/user/</D:href>
                    </D:current-user-principal>
                  </D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """)

          n == 3 ->
            # RFC 4791 step 2: calendar-home-set at principal URL
            assert conn.request_path == "/principals/users/user/"

            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, """
            <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
              <D:response>
                <D:propstat>
                  <D:prop>
                    <C:calendar-home-set>
                      <D:href>/calendars/user/</D:href>
                    </C:calendar-home-set>
                  </D:prop>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """)

          n == 4 ->
            # RFC 4791 step 3: list calendars at calendar-home-set
            assert conn.request_path == "/calendars/user/"

            conn
            |> Conn.put_resp_header("content-type", "application/xml")
            |> Conn.send_resp(207, "<D:multistatus xmlns:D=\"DAV:\"/>")
        end
      end)

      assert {:ok, []} = Discovery.discover_calendars(@caldav_client, skip_breaker: true)
    end

    test "returns error when current-user-principal href is missing from 207 response" do
      call_count = :counters.new(1, [:atomics])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        if n == 1 do
          Conn.send_resp(conn, 404, "")
        else
          # RFC 4791 probe — server returns 207 but omits current-user-principal
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, "<D:multistatus xmlns:D=\"DAV:\"><D:response/></D:multistatus>")
        end
      end)

      assert {:error, _reason} = Discovery.discover_calendars(@caldav_client, skip_breaker: true)
    end
  end

  # ---------------------------------------------------------------------------
  # discover_calendars/2 — URL validation (SSRF protection)
  # ---------------------------------------------------------------------------

  describe "discover_calendars/2 URL validation" do
    test "rejects plain HTTP URL pointing at a public host" do
      client = %{@caldav_client | base_url: "http://caldav.example.com"}

      assert {:error, _reason} =
               Discovery.discover_calendars(client, skip_breaker: true)
    end

    test "allows plain HTTP URL for a local/private host (self-hosted)" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, "<D:multistatus xmlns:D=\"DAV:\"/>")
      end)

      # localhost is a valid CalDAV target (e.g. a self-hosted Radicale instance)
      client = %{@caldav_client | base_url: "http://localhost:5232"}

      assert {:ok, _calendars} =
               Discovery.discover_calendars(client, skip_breaker: true)
    end
  end
end
