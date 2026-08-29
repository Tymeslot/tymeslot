defmodule Tymeslot.Integrations.Calendar.CalDAV.DiscoveryTest do
  use Tymeslot.CalDAVCase, async: false
  @moduletag :integrations

  import Tymeslot.CalDAVTestHelpers

  alias Tymeslot.Integrations.Calendar.CalDAV.Discovery

  @caldav_client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: [],
    verify_ssl: true,
    provider: :caldav
  }

  # A server that speaks DAV only under a subpath — the shape that makes the
  # origin root useless as the sole principal-probe target.
  @subpath_client %{@caldav_client | base_url: "https://caldav.example.com/caldav"}

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

    test "falls back to the full RFC 4791 chain when discovery path returns 404" do
      # A passing test must prove calendars are reachable, so the fallback runs
      # the complete principal → calendar-home-set → calendar-list chain.
      stub_rfc4791_chain(initial_status: 404)

      assert {:ok, _message} = Discovery.test_connection(@caldav_client, ip_address: "127.0.0.1")
    end

    test "falls back to the full RFC 4791 chain when discovery path returns 5xx" do
      stub_rfc4791_chain(initial_status: 500)

      assert {:ok, _msg} = Discovery.test_connection(@caldav_client, ip_address: "127.0.0.1")
    end

    test "fails when credentials are valid but no calendar collection is reachable" do
      # The iCloud false-positive guard: the guessed path 403s and the
      # current-user-principal probe succeeds (proving credentials), but the
      # calendar-home-set step fails. A credentials-only probe would have
      # reported success here; the full chain must report the error instead.
      call_count = :counters.new(1, [:atomics])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        cond do
          n == 1 ->
            # Guessed discovery path → 403 (iCloud's response)
            Conn.send_resp(conn, 403, "")

          n == 2 ->
            # current-user-principal probe succeeds — credentials are valid
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

          n >= 3 ->
            # calendar-home-set step fails — calendars cannot be listed
            Conn.send_resp(conn, 500, "Internal Server Error")
        end
      end)

      assert {:error, _reason} =
               Discovery.test_connection(@caldav_client, ip_address: "127.0.0.1")
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

  describe "discover_calendars/2 on a server mounted under a subpath" do
    test "discovers calendars when only the supplied URL answers, not the origin root" do
      # This server serves DAV at /caldav/ and 404s everywhere else, including
      # `/`. The URL the account owner supplied is the only possible start for
      # the principal chain, so a fallback that probes only the origin root can
      # never recover from the wrong guessed path here.
      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          "/caldav/" ->
            xml_response(conn, principal_xml("/caldav/users/user/"))

          "/caldav/users/user/" ->
            xml_response(conn, calendar_home_set_xml("/caldav/users/user/calendars/"))

          "/caldav/users/user/calendars/" ->
            xml_response(conn, calendar_list_xml())

          _unmounted ->
            Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:ok, [calendar]} = Discovery.discover_calendars(@subpath_client, skip_breaker: true)

      assert calendar.name == "Personal"
      assert calendar.path == "/caldav/users/user/calendars/1/"
      refute calendar.read_only
    end

    test "test_connection/2 succeeds against the same server" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          "/caldav/" ->
            xml_response(conn, principal_xml("/caldav/users/user/"))

          "/caldav/users/user/" ->
            xml_response(conn, calendar_home_set_xml("/caldav/users/user/calendars/"))

          "/caldav/users/user/calendars/" ->
            xml_response(conn, calendar_list_xml())

          _unmounted ->
            Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:ok, _message} =
               Discovery.test_connection(@subpath_client, ip_address: "127.0.0.1")
    end

    test "reports accepted credentials with unreachable calendars as its own failure" do
      # The principal probe proves the credentials are good; the calendar home
      # then 404s. Reporting a bare :not_found here sends the account owner off
      # to re-check the one thing already known to be correct.
      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.request_path do
          "/caldav/" -> xml_response(conn, principal_xml("/caldav/users/user/"))
          _missing -> Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:error, {:calendar_home_not_found, "https://caldav.example.com/caldav"}} =
               Discovery.discover_calendars(@subpath_client, skip_breaker: true)
    end

    test "stops probing candidates once the server rejects the credentials" do
      # A 401 is about the credentials, not the URL, so no further candidate is
      # tried: re-presenting a rejected login to a server that locks accounts
      # out on repeated failures makes the owner's situation worse.
      call_count = :counters.new(1, [:atomics])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(call_count, 1, 1)

        case conn.request_path do
          "/caldav/calendars/user/" -> Conn.send_resp(conn, 404, "")
          _everywhere_else -> Conn.send_resp(conn, 401, "")
        end
      end)

      assert {:error, :unauthorized} =
               Discovery.discover_calendars(@subpath_client, skip_breaker: true)

      # The guessed path, then one principal probe. The origin-root candidate
      # is never asked.
      assert :counters.get(call_count, 1) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # discover_calendars/2 — URL validation (SSRF protection)
  # ---------------------------------------------------------------------------

  describe "discover_calendars/2 URL validation (SSRF protection)" do
    test "rejects plain HTTP URL pointing at a public host" do
      client = %{@caldav_client | base_url: "http://caldav.example.com"}

      assert {:error, _reason} =
               Discovery.discover_calendars(client, skip_breaker: true)
    end

    # Discovery now mirrors the persistence posture (block_private_ips: true):
    # an authenticated user cannot drive server-side PROPFINDs at internal hosts
    # any more than they can save such a base_url on the integration.
    test "rejects loopback host (localhost)" do
      client = %{@caldav_client | base_url: "https://localhost:5232"}

      assert {:error, _reason} =
               Discovery.discover_calendars(client, skip_breaker: true)
    end

    test "rejects loopback IP (127.0.0.1)" do
      client = %{@caldav_client | base_url: "https://127.0.0.1:5232"}

      assert {:error, _reason} =
               Discovery.discover_calendars(client, skip_breaker: true)
    end

    test "rejects link-local cloud metadata endpoint (169.254.169.254)" do
      client = %{@caldav_client | base_url: "https://169.254.169.254"}

      assert {:error, _reason} =
               Discovery.discover_calendars(client, skip_breaker: true)
    end

    test "rejects RFC 1918 private host (10.x)" do
      client = %{@caldav_client | base_url: "https://10.0.0.5"}

      assert {:error, _reason} =
               Discovery.discover_calendars(client, skip_breaker: true)
    end
  end

  # Stubs the full RFC 4791 discovery chain: the guessed discovery path returns
  # `initial_status`, then current-user-principal → calendar-home-set → an empty
  # calendar list each return 207.
  defp xml_response(conn, body) do
    conn
    |> Conn.put_resp_header("content-type", "application/xml")
    |> Conn.send_resp(207, body)
  end

  # The collection itself plus one calendar, as a real server answers a Depth: 1
  # PROPFIND — the non-calendar collection must be filtered out.
  defp calendar_list_xml do
    """
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:href>/caldav/users/user/calendars/</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype><D:collection/></D:resourcetype>
            <D:displayname>Calendars</D:displayname>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/caldav/users/user/calendars/1/</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
            <D:displayname>Personal</D:displayname>
            <D:current-user-privilege-set>
              <D:privilege><D:read/></D:privilege>
              <D:privilege><D:write/></D:privilege>
            </D:current-user-privilege-set>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """
  end

  defp stub_rfc4791_chain(opts) do
    initial_status = Keyword.fetch!(opts, :initial_status)
    call_count = :counters.new(1, [:atomics])

    ReqTest.stub(:tymeslot_http, fn conn ->
      :counters.add(call_count, 1, 1)
      n = :counters.get(call_count, 1)

      cond do
        n == 1 ->
          Conn.send_resp(conn, initial_status, "")

        n == 2 ->
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

        n >= 4 ->
          conn
          |> Conn.put_resp_header("content-type", "application/xml")
          |> Conn.send_resp(207, "<D:multistatus xmlns:D=\"DAV:\"/>")
      end
    end)
  end

  describe "test_connection/2 URL validation (SSRF protection)" do
    test "rejects loopback IP before any network contact" do
      client = %{@caldav_client | base_url: "https://127.0.0.1:5232"}

      assert {:error, _reason} = Discovery.test_connection(client, ip_address: "127.0.0.1")
    end

    test "rejects link-local cloud metadata endpoint (169.254.169.254)" do
      client = %{@caldav_client | base_url: "https://169.254.169.254"}

      assert {:error, _reason} = Discovery.test_connection(client, ip_address: "127.0.0.1")
    end

    test "rejects RFC 1918 private host (10.x)" do
      client = %{@caldav_client | base_url: "https://10.0.0.5"}

      assert {:error, _reason} = Discovery.test_connection(client, ip_address: "127.0.0.1")
    end
  end
end
