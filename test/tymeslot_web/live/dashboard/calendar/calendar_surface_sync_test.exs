defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSyncTest do
  @moduledoc """
  The new calendar's sync status: stale accounts sync when it opens, a
  failed or discarded sync ends "Syncing", and the banner explains it only
  once the failure persists (a sync Oban will retry is not news), with the
  changes it holds back; Retry or Sync now asks again.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Phoenix.LiveView
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  setup %{conn: conn}, do: owner(conn)

  # A broadcast sent to the LiveView is queued behind its own work: the
  # first render lets it through, the second shows it.
  defp settled(lv) do
    render(lv)
    render(lv)
  end

  defp fail(lv, user, integration_id, times \\ 2) do
    for _attempt <- 1..times do
      send(lv.pid, {:calendar_sync_failed, user.id, integration_id})
      settled(lv)
    end

    :ok
  end

  defp syncing?(lv, integration),
    do: has_element?(lv, "#calendar-account-#{integration.id} [data-syncing]")

  test "opening the calendar syncs a stale account and shows it syncing", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert syncing?(lv, integration)
    assert_enqueued(worker: SyncGoogleCalendarWorker)
  end

  test "one failed attempt ends Syncing but is not yet worth a banner", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    fail(lv, user, integration.id, 1)

    refute syncing?(lv, integration)
    refute has_element?(lv, "#calendar-sync-problem-#{integration.id}")
    refute has_element?(lv, "#calendar-account-#{integration.id} [data-sync-problem]")
  end

  test "a failure that persists ends Syncing and says what it means", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    fail(lv, user, integration.id)

    refute syncing?(lv, integration)

    assert has_element?(
             lv,
             "#calendar-sync-problem-#{integration.id}",
             "Work account isn't responding. Its events may be out of date."
           )

    assert has_element?(lv, "#calendar-account-#{integration.id} [data-sync-problem]")
  end

  test "a sync that succeeds between two failures starts the count again", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    fail(lv, user, integration.id, 1)
    send(lv.pid, {:calendar_sync_complete, user.id, integration.id})
    settled(lv)
    fail(lv, user, integration.id, 1)

    refute has_element?(lv, "#calendar-sync-problem-#{integration.id}")
  end

  test "a failure for an integration the calendar does not show is ignored", %{
    conn: conn,
    user: user
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    fail(lv, user, 0, 3)

    refute has_element?(lv, "[id^=calendar-sync-problem-]")
  end

  test "a change waiting to be sent is named once the sync keeps failing", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    event(integration, "work", "Dentist", ~U[2026-10-15 14:00:00Z], 60,
      sync_state: "locally_modified"
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    fail(lv, user, integration.id)

    assert has_element?(
             lv,
             "#calendar-sync-problem-#{integration.id}",
             "Your change to “Dentist” is saved here and will be sent automatically."
           )
  end

  test "a change waiting to be sent is named even before any failure", %{
    conn: conn,
    integration: integration
  } do
    event(integration, "work", "Dentist", ~U[2026-10-15 14:00:00Z], 60,
      sync_state: "locally_modified"
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-sync-problem-#{integration.id}",
             "Your change to “Dentist” is saved here and will be sent to Work account automatically."
           )
  end

  test "a sync that later completes clears the banner", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    fail(lv, user, integration.id)
    assert has_element?(lv, "#calendar-sync-problem-#{integration.id}")

    send(lv.pid, {:calendar_sync_complete, user.id, integration.id})
    settled(lv)

    refute has_element?(lv, "#calendar-sync-problem-#{integration.id}")
  end

  test "Retry asks again and shows the account syncing", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    fail(lv, user, integration.id)
    refute syncing?(lv, integration)

    lv |> element("#calendar-sync-retry-#{integration.id}") |> render_click()

    assert syncing?(lv, integration)
  end

  test "Sync now in the rail asks for that account's sync", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    fail(lv, user, integration.id, 1)
    refute syncing?(lv, integration)

    lv |> element("#calendar-sync-#{integration.id}") |> render_click()

    assert syncing?(lv, integration)
  end

  test "an account that needs signing in again says so, with a way to reconnect", %{
    conn: conn,
    integration: integration
  } do
    integration |> Changeset.change(needs_reauth: true) |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-sync-problem-#{integration.id}",
             "Work account needs you to sign in again."
           )

    assert has_element?(lv, "#calendar-sync-problem-#{integration.id} a", "Reconnect")
  end

  test "a write saved for later is left to the banner, not a flash", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    write = {{integration.id, "uid-1"}, 1}

    send(lv.pid, {:event_update_result, {:error, %{retry: :queued, write: write}}})
    html = settled(lv)

    refute html =~ "Your calendar could not be reached"
  end

  describe "failures persisted before the calendar opened" do
    defp persist_failures(user, integration, count) do
      {:ok, _state} =
        IntegrationHealthStateQueries.get_or_init("calendar", integration.id, user.id)

      IntegrationHealthStateQueries.update_fields("calendar", integration.id,
        consecutive_sync_failures: count
      )
    end

    test "three in a row name the account on mount, without a broadcast", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      persist_failures(user, integration, 3)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(
               lv,
               "#calendar-sync-problem-#{integration.id}",
               "Work account isn't responding."
             )
    end

    test "a single one does not", %{conn: conn, user: user, integration: integration} do
      persist_failures(user, integration, 1)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      refute has_element?(lv, "#calendar-sync-problem-#{integration.id}")
    end
  end

  test "the timer of an earlier request does not stop a later request's spinner", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    fail(lv, user, integration.id, 1)
    lv |> element("#calendar-sync-#{integration.id}") |> render_click()
    assert syncing?(lv, integration)

    LiveView.send_update(lv.pid, CalendarSurface,
      id: "calendar",
      action: :sync_timeout,
      integration_id: integration.id,
      ref: make_ref()
    )

    settled(lv)

    assert syncing?(lv, integration)
  end
end
