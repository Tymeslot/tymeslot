defmodule TymeslotWeb.Dashboard.CalendarRoutingTest do
  @moduledoc """
  Calendar messages reach whichever calendar is on screen: a discarded sync
  ends the old calendar's "Syncing" banner without its fallback timer, and
  the new calendar ignores messages only the old one handles.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  use Oban.Testing, repo: Tymeslot.Repo

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Workers.CalendarEventDeleteWorker

  # A message to the LiveView becomes a component update, itself a message
  # queued behind it: the first render lets it through, the second shows it.
  defp settled(lv) do
    render(lv)
    render(lv)
  end

  test "a discarded sync ends the old calendar's syncing banner", %{conn: conn} do
    %{conn: conn, user: user, integration: integration} = owner(conn, redesign_enabled: false)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    assert settled(lv) =~ "Syncing calendars"

    send(lv.pid, {:calendar_sync_failed, user.id, integration.id})

    refute settled(lv) =~ "Syncing calendars"
  end

  test "the new calendar ignores what only the old one handles", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    settled(lv)

    send(lv.pid, {:ics_import_progress, 3})
    settled(lv)

    refute_push_event(lv, "calendar:period", %{}, 100)
  end

  describe "a scheduled delete's result" do
    test "reaches the new calendar, which brings a refused delete back", %{conn: conn} do
      %{conn: conn, user: user, integration: integration} = owner(conn)
      dentist = event(integration, "work", "Dentist", ~U[2026-10-15 14:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:delete", %{"id" => "event-#{dentist.id}"})

      assert has_element?(lv, "#calendar-toast", "Deleted “Dentist”")

      [job] = all_enqueued(worker: CalendarEventDeleteWorker)
      send(lv.pid, {:calendar_delete_result, user.id, job.id, {:failed, :forbidden}})

      assert settled(lv) =~ "Failed to delete event"
      refute has_element?(lv, "#calendar-toast", "Deleted “Dentist”")
    end

    test "a token this calendar never scheduled is taken quietly", %{conn: conn} do
      %{conn: conn, user: user} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:calendar_delete_result, user.id, 0, :deleted})

      assert settled(lv) =~ "calendar-surface"
      assert Process.alive?(lv.pid)
    end

    test "is ignored by the old calendar", %{conn: conn} do
      %{conn: conn, user: user} = owner(conn, redesign_enabled: false)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      send(lv.pid, {:calendar_delete_result, user.id, 1, {:failed, :forbidden}})

      refute settled(lv) =~ "Failed to delete event"
      assert Process.alive?(lv.pid)
    end
  end
end
