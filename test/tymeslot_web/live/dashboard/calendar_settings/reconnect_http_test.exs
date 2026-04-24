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
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter

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

      reloaded = Tymeslot.Repo.get!(CalendarIntegrationSchema, integration.id)
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

      reloaded = Tymeslot.Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth == true
      assert Encryption.decrypt(reloaded.password_encrypted) == "oldpass"
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
end
