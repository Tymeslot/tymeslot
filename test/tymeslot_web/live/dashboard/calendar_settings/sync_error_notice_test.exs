defmodule TymeslotWeb.Dashboard.CalendarSettings.SyncErrorNoticeTest do
  @moduledoc """
  A calendar connection whose syncs keep failing tells its owner why on its
  card, and stops saying so once a sync succeeds.

  Driven end to end: the real sync worker fails against a stubbed server,
  the integrations page shows the stored reason, and the next successful
  sync clears it. CalDAV and Exchange store their reasons through different
  workers, so each is covered.
  """

  # The failure threshold and the HTTP client are application config.
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :live
  @moduletag :calendar
  @moduletag :integrations

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.CalDAVSyncTestFixtures
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.ExchangeSyncStubs
  import Tymeslot.Factory

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.ExchangeCase
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  @exchange_url "https://mail.example.com/EWS/Exchange.asmx"

  setup :set_req_test_to_shared
  setup :setup_dashboard_user

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    # One failed cycle is enough to make the connection unhealthy here.
    with_config(:tymeslot, :sync_failure_unhealthy_threshold, 1)
    :ok
  end

  test "a CalDAV calendar whose sync is refused says so until a sync succeeds", %{
    conn: conn,
    user: user
  } do
    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        name: "Team CalDAV",
        is_active: true,
        base_url: "http://localhost:65432",
        username_encrypted: Encryption.encrypt("alice"),
        password_encrypted: Encryption.encrypt("s3cret"),
        calendar_paths: [path1()],
        caldav_sync_tier: 3
      )

    ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 418, "") end)
    assert {:discard, _reason} = sync_caldav(integration)

    assert notices(conn) == ["The calendar server refused the request."]

    ReqTest.stub(:tymeslot_http, fn conn ->
      conn
      |> Conn.put_resp_header("content-type", "application/xml")
      |> Conn.send_resp(207, caldav_report_xml("#{path1()}event1.ics", ical_path1()))
    end)

    assert :ok = sync_caldav(integration)

    assert notices(conn) == []
  end

  test "an Exchange calendar whose server fails says so until a sync succeeds", %{
    conn: conn,
    user: user
  } do
    ExchangeCase.reset_breaker(@exchange_url)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "exchange",
        name: "Work Exchange",
        is_active: true,
        base_url: @exchange_url,
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        provider_account_email: "user@example.com",
        calendar_list: []
      )

    ReqTest.stub(:tymeslot_http, fn conn -> Conn.resp(conn, 503, "") end)

    assert {:discard, _reason} = run(integration)

    assert notices(conn) == [
             "The calendar server reported an error. Tymeslot will retry automatically."
           ]

    stub_full_sync()
    assert :ok = run(integration)

    assert notices(conn) == []
  end

  test "a reconnected calendar drops the reason it was flagged for", %{conn: conn, user: user} do
    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        is_active: true,
        needs_reauth: true,
        sync_error:
          "The calendar server rejected the stored credentials. Please reconnect the calendar."
      )

    assert {:ok, reconnected} =
             Management.update_calendar_integration(integration, %{
               username: "alice",
               password: "new-password"
             })

    # A later failure that records no reason of its own, such as a refused
    # bulk deletion, still turns the card unhealthy.
    HealthCheck.record_sync_failure(:calendar, reconnected)

    assert HealthCheck.attention_status(reconnected, health_state(:calendar, reconnected)) ==
             :unhealthy

    assert notices(conn) == []
  end

  # Video cards show only a reconnection reason: a video integration's
  # `sync_error` is not written for every failure, so an unhealthy one keeps
  # it to itself, as before calendar cards began showing theirs.
  test "a failing video connection still shows no stored sync error", %{conn: conn, user: user} do
    video =
      insert(:video_integration,
        user: user,
        provider: "google_meet",
        is_active: true,
        needs_reauth: false,
        sync_error: "Timed out talking to the server."
      )

    HealthCheck.record_sync_failure(:video, video)
    assert HealthCheck.attention_status(video, health_state(:video, video)) == :unhealthy

    {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

    refute html =~ "Timed out talking to the server."
  end

  defp health_state(type, integration),
    do: Monitor.get_state(type, integration.id, integration.user_id)

  defp sync_caldav(integration),
    do: perform_job(SyncCalDavCalendarWorker, %{"calendar_integration_id" => integration.id})

  # The card notices on a fresh visit to the page; the user has one calendar.
  defp notices(conn) do
    {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-part='notice']")
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end
end
