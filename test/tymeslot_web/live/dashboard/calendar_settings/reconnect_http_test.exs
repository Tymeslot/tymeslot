defmodule TymeslotWeb.Dashboard.CalendarSettings.ReconnectHttpTest do
  @moduledoc """
  End-to-end tests for the CalDAV reconnect flow that exercise a real HTTP
  round-trip. The transport is stubbed with `Req.Test` — the project-wide
  convention for HTTP fakes — so the test drives the LiveView through the
  modal, the form submit, and the full CalDAV discovery pipeline down to the
  `HTTPClient → Req → Req.Test` boundary.

  These tests live in their own file because they require `async: false`:
  they flip the global `:http_client_module` config and share a Req.Test
  owner across process boundaries (the discovery work runs inside
  `CalendarCircuitBreaker`, a separate GenServer).
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :live
  @moduletag :integrations
  @moduletag :calendar

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  # Route CalDAV HTTP through the real HTTPClient so `Req.Test` can intercept
  # and assert on each request/response. The global test config wires
  # :http_client_module to a Mox mock by default.
  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})

    # A previous test may have tripped the breaker; reset so a single 401
    # here doesn't short-circuit the next run's PROPFIND.
    CalendarCircuitBreaker.reset(:caldav)
    RateLimiter.clear_all()
    :ok
  end

  setup :setup_dashboard_user

  describe "CalDAV reconnect submit (password-only, live HTTP)" do
    setup %{user: user} do
      # Port 65432 is unused on the CI host; Req.Test intercepts the request
      # at the transport plug so no actual socket is opened.
      base_url = "http://localhost:65432"

      integration =
        insert(:calendar_integration,
          user: user,
          name: "Bypass CalDAV",
          provider: "caldav",
          base_url: base_url,
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("oldpass"),
          calendar_paths: ["/calendars/alice/default/"],
          provider_account_id: "#{base_url}||alice",
          is_active: true,
          needs_reauth: true
        )

      %{integration: integration, base_url: base_url}
    end

    test "valid new password: updates record and clears needs_reauth", %{
      conn: conn,
      integration: integration
    } do
      stub_caldav_server(accept: "alice:newpass")

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']")
      |> render_click()

      view
      |> form("form[phx-submit='reconnect_caldav_discover']",
        reconnect: %{
          url: integration.base_url,
          username: "alice",
          password: "newpass"
        }
      )
      |> render_submit()

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth == false
      assert Encryption.decrypt(reloaded.password_encrypted) == "newpass"
    end

    test "invalid password: error shown, record unchanged", %{
      conn: conn,
      integration: integration
    } do
      # All requests return 401 — CalDAV HTTP maps both 401 and 403 to
      # {:error, :unauthorized}, which the Reconnection module translates
      # into {:error, :invalid_credentials}.
      ReqTest.stub(:tymeslot_http, fn conn -> Conn.resp(conn, 401, "") end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']")
      |> render_click()

      html =
        view
        |> form("form[phx-submit='reconnect_caldav_discover']",
          reconnect: %{
            url: integration.base_url,
            username: "alice",
            password: "bogus"
          }
        )
        |> render_submit()

      assert html =~ "Could not sign in with those credentials"

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth == true
      assert Encryption.decrypt(reloaded.password_encrypted) == "oldpass"
    end
  end

  describe "account change reconnect" do
    setup %{user: user} do
      base_url = "http://localhost:65432"

      integration =
        insert(:calendar_integration,
          user: user,
          name: "Account Change CalDAV",
          provider: "caldav",
          base_url: base_url,
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("oldpass"),
          calendar_paths: ["/calendars/alice/default/"],
          provider_account_id: "#{base_url}||alice",
          is_active: true,
          needs_reauth: false
        )

      %{integration: integration, base_url: base_url}
    end

    test "zero-calendar guard: submitting selection with no ticks shows an error", %{
      conn: conn,
      integration: integration
    } do
      # Use bob:newpass so credentials_change_kind returns :account_change.
      # The stub confirms auth and returns an empty multistatus, which the
      # discovery parser treats as an empty calendar list. The LiveView
      # advances to :calendar_selection; submitting without any ticked paths
      # must stay on that phase and show the "select at least one" message.
      stub_caldav_server(accept: "bob:newpass")

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']")
      |> render_click()

      view
      |> form("form[phx-submit='reconnect_caldav_discover']",
        reconnect: %{
          url: integration.base_url,
          username: "bob",
          password: "newpass"
        }
      )
      |> render_submit()

      # Submit the calendar-selection form with no paths selected.
      html =
        view
        |> element("form[phx-submit='reconnect_caldav_submit']")
        |> render_submit(%{})

      assert html =~ "Please select at least one calendar"

      # Modal stays on the calendar-selection phase — the submit button and
      # "Select calendars" heading must still be visible.
      assert html =~ "Select calendars to sync"

      # The DB record must be untouched.
      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.calendar_paths == ["/calendars/alice/default/"]
      assert Encryption.decrypt(reloaded.username_encrypted) == "alice"
    end

    test "auth error during discovery stays on credentials phase", %{
      conn: conn,
      integration: integration
    } do
      # Every request returns 401 so the discovery step fails with
      # {:error, :invalid_credentials} and the modal must NOT advance
      # to the calendar-selection phase.
      ReqTest.stub(:tymeslot_http, fn conn -> Conn.resp(conn, 401, "") end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']")
      |> render_click()

      html =
        view
        |> form("form[phx-submit='reconnect_caldav_discover']",
          reconnect: %{
            url: integration.base_url,
            username: "bob",
            password: "wrongpass"
          }
        )
        |> render_submit()

      assert html =~ "Could not sign in with those credentials"

      # The credentials form must still be present; no calendar-selection UI.
      refute html =~ "Select calendars to sync"

      # DB record unchanged.
      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert Encryption.decrypt(reloaded.username_encrypted) == "alice"
    end

    test "URL change persists new credentials and calendar_paths", %{
      conn: conn,
      integration: integration
    } do
      new_calendar_href = "/calendars/bob/work/"
      new_calendar_name = "Bob Work"

      stub_caldav_discovery_server(
        accept: "bob:newpass",
        calendar_href: new_calendar_href,
        calendar_name: new_calendar_name
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar-integration")

      view
      |> element("button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']")
      |> render_click()

      # Phase 1: submit changed credentials (username flip triggers :account_change).
      view
      |> form("form[phx-submit='reconnect_caldav_discover']",
        reconnect: %{
          url: integration.base_url,
          username: "bob",
          password: "newpass"
        }
      )
      |> render_submit()

      # The LiveView must now be in the :calendar_selection phase with the
      # discovered calendar visible.
      assert has_element?(view, "form[phx-submit='reconnect_caldav_submit']")
      assert render(view) =~ new_calendar_name

      # Phase 2: tick the new calendar and submit.
      view
      |> form("form[phx-submit='reconnect_caldav_submit']", %{
        "selected_paths" => [new_calendar_href]
      })
      |> render_submit()

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert Encryption.decrypt(reloaded.username_encrypted) == "bob"
      assert Encryption.decrypt(reloaded.password_encrypted) == "newpass"
      assert reloaded.calendar_paths == [new_calendar_href]
      assert reloaded.needs_reauth == false

      # Modal must close: the reconnect_integration assign is cleared.
      refute has_element?(view, "form[phx-submit='reconnect_caldav_submit']")
    end
  end

  describe "CalDAV badge lifecycle" do
    setup %{user: user} do
      base_url = "http://localhost:65432"

      integration =
        insert(:calendar_integration,
          user: user,
          name: "Lifecycle CalDAV",
          provider: "caldav",
          base_url: base_url,
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("oldpass"),
          calendar_paths: ["/calendars/alice/default/"],
          provider_account_id: "#{base_url}||alice",
          is_active: true,
          needs_reauth: false
        )

      %{integration: integration, base_url: base_url}
    end

    test "sync 401 flips needs_reauth; reconnect clears it", %{
      conn: conn,
      integration: integration
    } do
      # Phase 1: every CalDAV request returns 401 — the worker's tier-detection
      # probe fails and `log_auth_error/1` flips `needs_reauth` to true.
      ReqTest.stub(:tymeslot_http, fn http_conn -> Conn.send_resp(http_conn, 401, "") end)

      assert {:discard, _reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      flagged = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert flagged.needs_reauth == true

      {:ok, view, html} = live(conn, ~p"/dashboard/calendar-integration")
      assert html =~ "Reconnect required"

      # Phase 2: the server now accepts the rotated password and the user
      # reconnects through the modal. The badge must disappear.
      stub_caldav_server(accept: "alice:newpass")

      view
      |> element("button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']")
      |> render_click()

      view
      |> form("form[phx-submit='reconnect_caldav_discover']",
        reconnect: %{
          url: integration.base_url,
          username: "alice",
          password: "newpass"
        }
      )
      |> render_submit()

      refute render(view) =~ "Reconnect required"

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth == false
    end
  end

  # Serves any authenticated PROPFIND with an empty 207 multistatus and
  # rejects mismatched or missing Basic-auth headers with 401. The
  # password-only reconnect branch only needs the server to confirm
  # authentication succeeded; a bare multistatus response is enough for the
  # downstream discovery parser to return `{:ok, []}`.
  defp stub_caldav_server(accept: accept_basic) do
    ReqTest.stub(:tymeslot_http, fn http_conn ->
      case Conn.get_req_header(http_conn, "authorization") do
        ["Basic " <> encoded] ->
          case Base.decode64(encoded) do
            {:ok, ^accept_basic} ->
              http_conn
              |> Conn.put_resp_header("content-type", "application/xml")
              |> Conn.resp(
                207,
                ~s|<?xml version="1.0"?><multistatus xmlns="DAV:"/>|
              )

            _other ->
              Conn.resp(http_conn, 401, "")
          end

        _no_header ->
          Conn.resp(http_conn, 401, "")
      end
    end)
  end

  # Responds to authenticated PROPFINDs with a single-calendar 207, driving the
  # discovery parser to return one calendar entry. Used for the account-change
  # happy-path test where calendar selection must be exercised.
  defp stub_caldav_discovery_server(opts) do
    accept_basic = Keyword.fetch!(opts, :accept)
    calendar_href = Keyword.fetch!(opts, :calendar_href)
    calendar_name = Keyword.fetch!(opts, :calendar_name)

    ReqTest.stub(:tymeslot_http, fn http_conn ->
      with ["Basic " <> encoded] <- Conn.get_req_header(http_conn, "authorization"),
           {:ok, ^accept_basic} <- Base.decode64(encoded) do
        respond_caldav(http_conn, calendar_href, calendar_name)
      else
        _ -> Conn.resp(http_conn, 401, "")
      end
    end)
  end

  defp respond_caldav(conn, calendar_href, calendar_name) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    cond do
      String.contains?(body, "current-user-principal") ->
        xml_multistatus(conn, """
          <response>
            <href>#{conn.request_path}</href>
            <propstat>
              <prop>
                <current-user-principal xmlns="DAV:"><href>/principals/bob/</href></current-user-principal>
              </prop>
              <status>HTTP/1.1 200 OK</status>
            </propstat>
          </response>
        """)

      String.contains?(body, "calendar-home-set") ->
        xml_multistatus(conn, """
          <response>
            <href>#{conn.request_path}</href>
            <propstat>
              <prop>
                <calendar-home-set xmlns="urn:ietf:params:xml:ns:caldav">
                  <href xmlns="DAV:">/calendars/bob/</href>
                </calendar-home-set>
              </prop>
              <status>HTTP/1.1 200 OK</status>
            </propstat>
          </response>
        """)

      true ->
        # Calendar listing — return one valid calendar at the requested href.
        xml_multistatus(conn, """
          <response>
            <href>#{calendar_href}</href>
            <propstat>
              <prop>
                <displayname>#{calendar_name}</displayname>
                <resourcetype>
                  <collection/>
                  <calendar xmlns="urn:ietf:params:xml:ns:caldav"/>
                </resourcetype>
              </prop>
              <status>HTTP/1.1 200 OK</status>
            </propstat>
          </response>
        """)
    end
  end

  defp xml_multistatus(conn, inner) do
    xml = ~s|<?xml version="1.0"?><multistatus xmlns="DAV:">#{inner}</multistatus>|

    conn
    |> Conn.put_resp_header("content-type", "application/xml")
    |> Conn.resp(207, xml)
  end
end
