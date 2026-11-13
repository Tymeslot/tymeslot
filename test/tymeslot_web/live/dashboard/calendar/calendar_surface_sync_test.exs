defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSyncTest do
  @moduledoc """
  The calendar's sync status: stale accounts sync when it opens, a
  failed or discarded sync ends "Syncing", and the banner explains it only
  once the failure persists (a sync Oban will retry is not news), with the
  changes it holds back; Retry or Sync now asks again.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Ecto.Query, only: [from: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Phoenix.LiveView
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
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

  defp persist_failures(user, integration, count) do
    {:ok, _state} =
      IntegrationHealthStateQueries.get_or_init("calendar", integration.id, user.id)

    IntegrationHealthStateQueries.update_fields("calendar", integration.id,
      consecutive_sync_failures: count
    )
  end

  defp flush_pushes do
    receive do
      {_ref, {:push_event, _event, _payload}} -> flush_pushes()
    after
      0 -> :ok
    end
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
    refute_push_event(lv, "calendar:events", %{}, 500)
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

  describe "Sync now and Retry are rate limited like Refresh" do
    test "a refused one shows no spinner and says to wait", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      fail(lv, user, integration.id, 1)
      refute syncing?(lv, integration)

      for _hit <- 1..10, do: RateLimiter.check(:calendar_refresh, user.id)
      on_exit(fn -> RateLimiter.clear_bucket("calendar_refresh:#{user.id}") end)

      lv |> element("#calendar-sync-#{integration.id}") |> render_click()

      refute syncing?(lv, integration)

      assert has_element?(
               lv,
               "#calendar-toast",
               "You've asked for several syncs recently. Try again in a few minutes."
             )
    end

    test "opening the calendar is not counted against it", %{conn: conn, user: user} do
      for _hit <- 1..9, do: RateLimiter.check(:calendar_refresh, user.id)
      on_exit(fn -> RateLimiter.clear_bucket("calendar_refresh:#{user.id}") end)

      {:ok, _lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert RateLimiter.check(:calendar_refresh, user.id) == :ok
    end
  end

  test "an account whose sync is waiting out a backoff is left to it on open", %{
    conn: conn,
    integration: integration
  } do
    {:ok, job} =
      %{"calendar_integration_id" => integration.id}
      |> SyncGoogleCalendarWorker.new()
      |> Oban.insert()

    backoff_until = DateTime.add(DateTime.utc_now(), 240, :second)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "retryable", scheduled_at: backoff_until, attempt: 1]
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute syncing?(lv, integration)
    assert Repo.get!(Oban.Job, job.id).scheduled_at == backoff_until
  end

  test "an account that keeps failing is not synced again on open", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    persist_failures(user, integration, 2)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute syncing?(lv, integration)
    refute_enqueued(worker: SyncGoogleCalendarWorker)
  end

  test "a sync discarded for rejected credentials shows the account needing sign-in", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    refute has_element?(lv, "#calendar-sync-problem-#{integration.id}")

    integration |> Changeset.change(needs_reauth: true) |> Repo.update!()
    send(lv.pid, {:calendar_sync_failed, user.id, integration.id})
    assert_push_event(lv, "calendar:events", %{reset: true}, 1_000)

    assert has_element?(
             lv,
             "#calendar-sync-problem-#{integration.id}",
             "Work account needs you to sign in again."
           )
  end

  test "a change waiting to be sent is named after a queued write, until a sync clears it", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    dentist =
      event(integration, "work", "Dentist", ~U[2026-10-15 14:00:00Z], 60, sync_state: "synced")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    refute has_element?(lv, "#calendar-sync-problem-#{integration.id}")

    dentist |> Changeset.change(sync_state: "locally_modified") |> Repo.update!()
    write = {{integration.id, "uid-1"}, 1}
    send(lv.pid, {:event_update_result, {:error, %{retry: :queued, write: write}}})
    assert_push_event(lv, "calendar:events", %{reset: true}, 1_000)

    assert has_element?(lv, "#calendar-sync-problem-#{integration.id}", "Dentist")

    # The queued write may push the window more than once; only the push the
    # sync causes may satisfy the next wait.
    flush_pushes()
    dentist |> Repo.reload!() |> Changeset.change(sync_state: "synced") |> Repo.update!()
    send(lv.pid, {:calendar_sync_complete, user.id, integration.id})
    assert_push_event(lv, "calendar:events", %{reset: true}, 1_000)

    refute has_element?(lv, "#calendar-sync-problem-#{integration.id}")
  end

  test "a change on a hidden calendar is still named", %{
    conn: conn,
    integration: integration
  } do
    event(integration, "family", "Piano", ~U[2026-10-15 14:00:00Z], 60,
      sync_state: "locally_modified"
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("[data-calendar-id='family']") |> render_click()

    assert has_element?(lv, "#calendar-sync-problem-#{integration.id}", "Piano")
  end

  test "the banner container is the live region, not each row", %{
    conn: conn,
    integration: integration
  } do
    event(integration, "work", "Dentist", ~U[2026-10-15 14:00:00Z], 60,
      sync_state: "locally_modified"
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-sync-banner[role=status][aria-live=polite]")
    refute has_element?(lv, "#calendar-sync-problem-#{integration.id}[role=status]")
  end

  describe "an account that needs signing in again" do
    test "is not synced on open, and has no Sync now in the rail", %{
      conn: conn,
      integration: integration
    } do
      integration |> Changeset.change(needs_reauth: true) |> Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      refute syncing?(lv, integration)
      refute_enqueued(worker: SyncGoogleCalendarWorker)
      refute has_element?(lv, "#calendar-sync-#{integration.id}")
      assert has_element?(lv, "#calendar-sync-problem-#{integration.id} a", "Reconnect")
    end
  end
end
