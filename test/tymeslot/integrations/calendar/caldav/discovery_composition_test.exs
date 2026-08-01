defmodule Tymeslot.Integrations.Calendar.CalDAV.DiscoveryCompositionTest do
  @moduledoc """
  End-to-end composition tests for the CalDAV discovery flow that the
  existing per-step tests in `discovery_test.exs` don't cover:

    * **Happy path** — valid server + credentials → the caller receives
      a non-empty list of named calendars ready to render in the
      calendar-picker UI. `discovery_test.exs` exercises the RFC 4791
      chain but only asserts `{:ok, []}`; nothing pins the populated
      list shape that the user actually sees.
    * **Failure path** — a 401 at any step of the chain surfaces as
      `{:error, :unauthorized}`, not a generic 500/invalid-response.
      This is the only signal the controller can use to render a
      credentials-specific error instead of a server error banner.
  """

  use Tymeslot.CalDAVCase, async: false

  @moduletag :integrations
  @moduletag :integration

  alias Tymeslot.Integrations.Calendar.CalDAV.Discovery

  @caldav_client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: [],
    verify_ssl: true,
    provider: :caldav
  }

  describe "discover_calendars/2 — user-observable outcomes" do
    test "happy path returns parsed calendars with names and hrefs" do
      # The guessed discovery path returns a populated calendar-home-set
      # response. The user should end up with a list they can render
      # in the picker, keyed by href and labelled by displayname.
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, """
        <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <D:response>
            <D:href>/calendars/user/work/</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>Work</D:displayname>
                <D:resourcetype>
                  <D:collection/>
                  <C:calendar/>
                </D:resourcetype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/calendars/user/personal/</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>Personal</D:displayname>
                <D:resourcetype>
                  <D:collection/>
                  <C:calendar/>
                </D:resourcetype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """)
      end)

      assert {:ok, calendars} =
               Discovery.discover_calendars(@caldav_client, skip_breaker: true)

      assert length(calendars) == 2
      names = calendars |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Personal", "Work"]

      paths = calendars |> Enum.map(& &1.path) |> Enum.sort()
      assert paths == ["/calendars/user/personal/", "/calendars/user/work/"]

      # The controller renders the picker unsaved — none of the returned
      # entries should default to selected without an explicit opt-in.
      refute Enum.any?(calendars, & &1.selected)
    end

    test "a 401 on the first PROPFIND surfaces as {:error, :unauthorized}" do
      # `discover_calendars/2` short-circuits on the first PROPFIND when the
      # server returns 401 — the RFC 4791 fallback chain only runs for
      # :not_found / :server_error. The distinguishable `:unauthorized`
      # atom is what lets the caller render "check your credentials"
      # rather than a generic 500 error.
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "")
      end)

      assert {:error, :unauthorized} =
               Discovery.discover_calendars(
                 %{@caldav_client | password: "bad"},
                 skip_breaker: true
               )
    end

    test "a 401 mid-chain (after a 404 first PROPFIND) still surfaces as {:error, :unauthorized}" do
      # Pins the RFC 4791 fallback path: first PROPFIND returns 404 so the
      # discovery chain enters `discover_via_rfc4791/1`; each subsequent
      # step returns 401. The caller must still see `:unauthorized`, not
      # :not_found or a generic error — otherwise the UI would ask the
      # user to check the server URL instead of their credentials.
      stub_sequential(
        fn conn -> Conn.send_resp(conn, 404, "") end,
        fn conn -> Conn.send_resp(conn, 401, "") end
      )

      assert {:error, :unauthorized} =
               Discovery.discover_calendars(
                 %{@caldav_client | password: "bad"},
                 skip_breaker: true
               )
    end
  end
end
