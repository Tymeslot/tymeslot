defmodule TymeslotWeb.Dashboard.CalendarSettings.StuckChangesTest do
  @moduledoc """
  An owner whose CalDAV server kept refusing a change made in Tymeslot sees
  it on the calendar's card, with what the server last said, and retries it
  from there: the notice goes, and the next sync sends the change.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :live
  @moduletag :calendar

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :setup_dashboard_user

  setup %{user: user} do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    RateLimiter.clear_all()

    integration =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    row =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "edited-uid",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/edited-uid.ics",
        summary: "Edited here",
        start_at: ~U[2026-11-02 10:00:00.000000Z],
        end_at: ~U[2026-11-02 11:00:00.000000Z],
        etag: "\"cached-etag\"",
        sync_state: "locally_modified",
        sync_attempts: 10,
        sync_last_error: "The server refused the change."
      )

    %{integration: integration, row: row}
  end

  defp retry_button(view, integration),
    do: element(view, "button[phx-click='retry_stuck_changes'][phx-value-id='#{integration.id}']")

  # The banner is the one place an owner who never opens the Calendars tab
  # learns that the calendar differs from the grid.
  test "the hub's attention banner lists the stuck change until it is retried", %{
    conn: conn,
    integration: integration
  } do
    integration |> Changeset.change(name: "Home server") |> Repo.update!()

    {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    assert html =~ "1 connection needs attention"
    assert html =~ "Home server: 1 change made here was not saved to the calendar."
    assert has_element?(view, "a[href='/dashboard/integrations?tab=calendars']", "Review")

    view |> retry_button(integration) |> render_click()

    {:ok, _view, reloaded} = live(conn, ~p"/dashboard/integrations?tab=calendars")
    refute reloaded =~ "needs attention"
  end

  # A paused calendar sends nothing and offers no retry, so its banner line
  # says it is paused (or nothing), not that changes are stuck.
  test "a paused calendar's stuck changes stay off the banner", %{
    conn: conn,
    integration: integration
  } do
    integration |> Changeset.change(is_active: false) |> Repo.update!()

    {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    refute html =~ "was not saved to the calendar"
  end

  test "the card names the stuck change and Retry sends it again", %{
    conn: conn,
    integration: integration,
    row: row
  } do
    {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    assert html =~ "1 change made here was not saved to this calendar."
    assert html =~ "The server refused the change."
    assert has_element?(retry_button(view, integration))

    html = view |> retry_button(integration) |> render_click()

    refute html =~ "was not saved to this calendar"
    refute has_element?(retry_button(view, integration))

    assert [%{args: %{"force_full_fetch" => true}}] =
             all_enqueued(worker: SyncCalDavCalendarWorker)

    ReqTest.stub(:tymeslot_http, &Conn.send_resp(&1, 204, ""))

    OfflineQueue.flush(integration, %{
      base_url: "https://caldav.example.com",
      username: "user",
      password: "pass",
      calendar_paths: ["/cal/"],
      provider: :caldav
    })

    assert Repo.reload!(row).sync_state == "synced"
  end

  test "a calendar with nothing stuck shows no notice and no Retry", %{
    conn: conn,
    integration: integration,
    row: row
  } do
    Repo.update!(Changeset.change(row, sync_attempts: 9))

    {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    refute html =~ "was not saved to this calendar"
    refute has_element?(retry_button(view, integration))
  end
end
