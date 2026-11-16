defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceDeleteTest do
  @moduledoc """
  Deleting on the calendar: an event nobody is told about goes at once
  with Undo; one whose guests or booking would be told asks first; a
  repeating one asks for this event or all of them; and the grid follows the
  delete once it has run.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Phoenix.ConnTest
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventDeleteWorker

  setup %{conn: conn}, do: owner(conn)

  defp canvas(lv, name, params),
    do: lv |> element("#calendar-canvas") |> render_hook(name, params)

  defp pushed_ids(lv) do
    assert_push_event(lv, "calendar:events", %{events: events})
    Enum.map(events, & &1.id)
  end

  defp dentist(%{conn: conn, integration: integration}) do
    dentist = event(integration, "work", "Dentist", ~U[2026-10-15 14:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    {lv, dentist, "event-#{dentist.id}"}
  end

  test "Delete in the preview removes the event at once and offers Undo", context do
    {lv, dentist, id} = dentist(context)

    canvas(lv, "calendar:open", %{"id" => id})
    lv |> element("#calendar-preview-delete") |> render_click()

    refute id in pushed_ids(lv)
    refute has_element?(lv, "#calendar-preview")
    assert has_element?(lv, "#calendar-toast", "Deleted “Dentist”")
    assert has_element?(lv, "#calendar-undo")

    assert_enqueued(
      worker: CalendarEventDeleteWorker,
      args: %{
        "uid" => dentist.uid,
        "scope" => "occurrence",
        "user_id" => context.user.id,
        "notify_attendees" => false
      }
    )
  end

  test "Undo brings it back before anything is deleted", context do
    {lv, _dentist, id} = dentist(context)
    canvas(lv, "calendar:delete", %{"id" => id})
    pushed_ids(lv)

    lv |> element("#calendar-undo") |> render_click()

    assert id in pushed_ids(lv)
    assert has_element?(lv, "#calendar-toast", "“Dentist” is back")
    refute_enqueued(worker: CalendarEventDeleteWorker)
  end

  test "an event on a read-only calendar offers no Delete and refuses one", %{
    conn: conn,
    integration: integration
  } do
    integration
    |> Changeset.change(
      calendar_list: [
        %{"id" => "work", "name" => "Work", "selected" => true},
        %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
      ]
    )
    |> Repo.update!()

    shared = event(integration, "shared", "Team offsite", ~U[2026-10-16 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    canvas(lv, "calendar:open", %{"id" => "event-#{shared.id}"})
    refute has_element?(lv, "#calendar-preview-delete")

    canvas(lv, "calendar:delete", %{"id" => "event-#{shared.id}"})
    assert render(lv) =~ "This calendar is read-only"
    refute_enqueued(worker: CalendarEventDeleteWorker)
  end

  test "an event with a guest asks first; telling them deletes it straight away", %{
    conn: conn,
    integration: integration
  } do
    call =
      event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
        attendees: [%{"email" => "ada@example.com"}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    canvas(lv, "calendar:delete", %{"id" => "event-#{call.id}"})

    assert has_element?(lv, "#calendar-delete-confirm", "It has 1 guest.")
    refute_enqueued(worker: CalendarEventDeleteWorker)

    lv |> element("#calendar-delete-notify") |> render_click()

    assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"notify_attendees" => true})
    refute has_element?(lv, "#calendar-undo")
  end

  test "the copy of a cancelled booking deletes at once, without offering to email the guest", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    copy =
      event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
        attendees: [%{"email" => "ada@example.com"}]
      )

    insert(:meeting,
      organizer_user: user,
      organizer_user_id: user.id,
      calendar_integration_id: integration.id,
      calendar_uid: copy.uid,
      status: "cancelled"
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    canvas(lv, "calendar:delete", %{"id" => "event-#{copy.id}"})

    refute has_element?(lv, "#calendar-delete-confirm")
    assert has_element?(lv, "#calendar-undo")
    assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"notify_attendees" => false})
  end

  test "deleting without telling the guest can still be undone", %{
    conn: conn,
    integration: integration
  } do
    call =
      event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
        attendees: [%{"email" => "ada@example.com"}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    canvas(lv, "calendar:delete", %{"id" => "event-#{call.id}"})
    lv |> element("#calendar-delete-quietly") |> render_click()

    assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"notify_attendees" => false})
    assert has_element?(lv, "#calendar-undo")
  end

  test "a repeating event asks for this event or all; all hides every one loaded", %{
    conn: conn,
    integration: integration
  } do
    monday =
      event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
        recurring_event_id: "standup-series"
      )

    tuesday =
      event(integration, "work", "Standup", ~U[2026-10-15 08:30:00Z], 15,
        recurring_event_id: "standup-series"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    canvas(lv, "calendar:delete", %{"id" => "event-#{monday.id}"})

    assert has_element?(lv, "#calendar-scope-occurrence")
    lv |> element("#calendar-scope-series") |> render_click()

    ids = pushed_ids(lv)
    refute "event-#{monday.id}" in ids
    refute "event-#{tuesday.id}" in ids
    assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"scope" => "series"})
  end

  test "once the delete has run the event stays gone, and Undo says it is too late", context do
    {lv, dentist, id} = dentist(context)
    canvas(lv, "calendar:delete", %{"id" => id})
    pushed_ids(lv)

    [job] = all_enqueued(worker: CalendarEventDeleteWorker)
    Repo.delete!(dentist)
    send(lv.pid, {:calendar_delete_result, context.user.id, job.id, :deleted})

    refute id in pushed_ids(lv)
    canvas(lv, "calendar:undo", %{})

    assert has_element?(
             lv,
             "#calendar-toast",
             "Too late to undo: “Dentist” has already been deleted."
           )

    # The marker is spent: the next Ctrl Z finds nothing.
    canvas(lv, "calendar:undo", %{})
    assert has_element?(lv, "#calendar-toast", "Nothing to undo.")
  end

  test "a delete the calendar refused brings the event back and says so", context do
    {lv, _dentist, id} = dentist(context)
    canvas(lv, "calendar:delete", %{"id" => id})
    pushed_ids(lv)

    [job] = all_enqueued(worker: CalendarEventDeleteWorker)
    send(lv.pid, {:calendar_delete_result, context.user.id, job.id, {:failed, :forbidden}})

    assert id in pushed_ids(lv)
    assert render(lv) =~ "Failed to delete event"
  end

  # The hook's first request, naming the browser tab it runs in (`nil` for
  # a browser that keeps no sessionStorage).
  defp ready_ids(lv, tab \\ nil) do
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{"tab" => tab})
    assert_reply(lv, %{events: events})
    Enum.map(events, & &1.id)
  end

  # The newest payload pushed so far.
  defp latest_ids(lv, last \\ nil) do
    assert_push_event(lv, "calendar:events", %{events: events}, 1_000)
    drain_ids(lv, Enum.map(events, & &1.id))
  rescue
    ExUnit.AssertionError -> last || []
  end

  defp drain_ids(lv, last) do
    assert_push_event(lv, "calendar:events", %{events: events}, 50)
    drain_ids(lv, Enum.map(events, & &1.id))
  rescue
    ExUnit.AssertionError -> last
  end

  describe "a scheduled delete survives the surface that scheduled it" do
    test "a reload of the tab that deleted keeps the event hidden and Undo still cancels it",
         context do
      {lv, _dentist, id} = dentist(context)
      ready_ids(lv, "tab-a")
      canvas(lv, "calendar:delete", %{"id" => id})
      assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"tab" => "tab-a"})

      {:ok, again, _html} = live(context.conn, ~p"/dashboard/calendar")
      refute has_element?(again, "#calendar-undo")

      refute id in ready_ids(again, "tab-a")
      assert has_element?(again, "#calendar-toast", "Deleted “Dentist”")

      again |> element("#calendar-undo") |> render_click()

      assert id in latest_ids(again)
      assert has_element?(again, "#calendar-toast", "“Dentist” is back")
      refute_enqueued(worker: CalendarEventDeleteWorker)
    end

    test "a reload of another tab keeps the event hidden but offers no Undo", context do
      {lv, _dentist, id} = dentist(context)
      ready_ids(lv, "tab-a")
      canvas(lv, "calendar:delete", %{"id" => id})

      {:ok, tab_b, _html} = live(context.conn, ~p"/dashboard/calendar")

      refute id in ready_ids(tab_b, "tab-b")
      refute has_element?(tab_b, "#calendar-undo")
      refute has_element?(tab_b, "#calendar-toast", "Deleted “Dentist”")

      canvas(tab_b, "calendar:undo", %{})
      assert has_element?(tab_b, "#calendar-toast", "Nothing to undo.")
      assert_enqueued(worker: CalendarEventDeleteWorker)
    end

    # A browser that keeps no sessionStorage names no tab, and a job stored
    # before tabs were carries none: neither is offered back to anyone.
    test "a delete from a tab with no id is offered Undo nowhere after a reload", context do
      {lv, _dentist, id} = dentist(context)
      ready_ids(lv)
      canvas(lv, "calendar:delete", %{"id" => id})
      assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"tab" => nil})

      {:ok, again, _html} = live(context.conn, ~p"/dashboard/calendar")
      refute id in ready_ids(again)
      refute has_element?(again, "#calendar-undo")

      {:ok, named, _html} = live(context.conn, ~p"/dashboard/calendar")
      refute id in ready_ids(named, "tab-a")
      refute has_element?(named, "#calendar-undo")
    end

    test "a delete that has already started stays hidden but offers no Undo", context do
      {lv, _dentist, id} = dentist(context)
      ready_ids(lv, "tab-a")
      canvas(lv, "calendar:delete", %{"id" => id})

      [job] = all_enqueued(worker: CalendarEventDeleteWorker)

      job
      |> Changeset.change(state: "executing")
      |> Repo.update!()

      {:ok, again, _html} = live(context.conn, ~p"/dashboard/calendar")

      refute id in ready_ids(again, "tab-a")
      refute has_element?(again, "#calendar-undo")
    end

    test "a series delete hides an occurrence in a week that loads later", %{
      conn: conn,
      integration: integration
    } do
      this_week =
        event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
          recurring_event_id: "standup-series"
        )

      later =
        event(integration, "work", "Standup", ~U[2026-11-04 08:30:00Z], 15,
          recurring_event_id: "standup-series"
        )

      other = event(integration, "work", "Lunch", ~U[2026-11-04 12:00:00Z])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas(lv, "calendar:delete", %{"id" => "event-#{this_week.id}"})
      lv |> element("#calendar-scope-series") |> render_click()
      latest_ids(lv)

      canvas(lv, "calendar:goto", %{"view" => "week", "date" => "2026-11-04"})
      ids = latest_ids(lv)

      assert "event-#{other.id}" in ids
      refute "event-#{later.id}" in ids
    end

    test "an occurrence delete hides only that occurrence after a remount", %{
      conn: conn,
      integration: integration
    } do
      monday =
        event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
          recurring_event_id: "standup-series"
        )

      tuesday =
        event(integration, "work", "Standup", ~U[2026-10-15 08:30:00Z], 15,
          recurring_event_id: "standup-series"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas(lv, "calendar:delete", %{"id" => "event-#{monday.id}"})
      lv |> element("#calendar-scope-occurrence") |> render_click()

      {:ok, again, _html} = live(conn, ~p"/dashboard/calendar")
      ids = ready_ids(again)

      refute "event-#{monday.id}" in ids
      assert "event-#{tuesday.id}" in ids
    end
  end

  # A message to the LiveView becomes a component update, itself a message
  # queued behind it: the first render lets it through, the second shows it.
  defp settled(lv) do
    render(lv)
    render(lv)
  end

  describe "another tab of the same organiser" do
    test "undo in one tab brings the event back in the other", context do
      {tab_a, _dentist, id} = dentist(context)
      ready_ids(tab_a, "tab-a")
      canvas(tab_a, "calendar:delete", %{"id" => id})

      {:ok, tab_b, _html} = live(context.conn, ~p"/dashboard/calendar")
      refute id in ready_ids(tab_b, "tab-b")
      refute has_element?(tab_b, "#calendar-undo")

      tab_a |> element("#calendar-undo") |> render_click()
      settled(tab_b)

      assert id in latest_ids(tab_b)
      refute has_element?(tab_b, "#calendar-toast", "Deleted “Dentist”")

      canvas(tab_b, "calendar:undo", %{})
      assert has_element?(tab_b, "#calendar-toast", "Nothing to undo.")
      refute_enqueued(worker: CalendarEventDeleteWorker)
    end

    test "a delete made in one tab hides the event in the other, without Undo", context do
      {tab_a, _dentist, id} = dentist(context)
      {:ok, tab_b, _html} = live(context.conn, ~p"/dashboard/calendar")
      assert id in ready_ids(tab_b)

      canvas(tab_a, "calendar:delete", %{"id" => id})
      settled(tab_b)

      refute id in latest_ids(tab_b)
      refute has_element?(tab_b, "#calendar-undo")

      # When it has run, the tab that deleted says so; this one stays quiet.
      [job] = all_enqueued(worker: CalendarEventDeleteWorker)
      send(tab_b.pid, {:calendar_delete_result, context.user.id, job.id, :deleted})
      settled(tab_b)
      refute has_element?(tab_b, "#calendar-toast")

      canvas(tab_b, "calendar:undo", %{})
      assert has_element?(tab_b, "#calendar-toast", "Nothing to undo.")
    end

    # Tab B is a reload of tab A, so it offers the Undo; tab A undoes first.
    test "an Undo for a delete the other tab already undid says nothing is wrong", context do
      {tab_a, _dentist, id} = dentist(context)
      ready_ids(tab_a, "tab-a")
      canvas(tab_a, "calendar:delete", %{"id" => id})
      {:ok, tab_b, _html} = live(context.conn, ~p"/dashboard/calendar")
      ready_ids(tab_b, "tab-a")
      [job] = all_enqueued(worker: CalendarEventDeleteWorker)

      # Cancelled behind tab B's back: no announcement reached it.
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "cancelled"])
      tab_b |> element("#calendar-undo") |> render_click()

      assert id in latest_ids(tab_b)
      refute render(tab_b) =~ "Too late"
      refute render(tab_b) =~ "already being deleted"
    end

    test "a hidden event outlives its delete only until the next reload", context do
      {lv, dentist, id} = dentist(context)
      assert id in ready_ids(lv)

      # Announced for a job that is no longer waiting (it ran, or was undone).
      address = Map.take(dentist, [:uid, :calendar_integration_id, :provider_event_id])
      send(lv.pid, {:calendar_delete_scheduled, context.user.id, 0, address, :occurrence})
      settled(lv)
      refute id in latest_ids(lv)

      send(lv.pid, {:calendar_events_updated, context.user.id, []})

      assert id in latest_ids(lv)
    end
  end

  describe "a delete that cannot be undone" do
    test "a confirmed delete is not offered Undo after a remount, even once snoozed", %{
      conn: conn,
      integration: integration
    } do
      call =
        event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
          attendees: [%{"email" => "ada@example.com"}]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      ready_ids(lv, "tab-a")
      canvas(lv, "calendar:delete", %{"id" => "event-#{call.id}"})
      lv |> element("#calendar-delete-notify") |> render_click()

      [job] = all_enqueued(worker: CalendarEventDeleteWorker)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "scheduled", scheduled_at: DateTime.add(DateTime.utc_now(), 60)]
      )

      {:ok, again, _html} = live(conn, ~p"/dashboard/calendar")

      refute "event-#{call.id}" in ready_ids(again, "tab-a")
      refute has_element?(again, "#calendar-undo")
    end

    test "Undo after the delete has started says it is already being deleted", context do
      {lv, _dentist, id} = dentist(context)
      canvas(lv, "calendar:delete", %{"id" => id})
      [job] = all_enqueued(worker: CalendarEventDeleteWorker)
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

      lv |> element("#calendar-undo") |> render_click()

      assert has_element?(lv, "#calendar-toast", "“Dentist” is already being deleted.")
      refute id in latest_ids(lv)
    end

    test "the calendar copy of a booking asks, offers no quiet delete and cannot be undone", %{
      conn: conn,
      integration: integration
    } do
      copy = event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30)

      insert(:meeting,
        calendar_integration_id: integration.id,
        calendar_uid: copy.uid,
        attendee_email: "guest@example.com"
      )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas(lv, "calendar:delete", %{"id" => "event-#{copy.id}"})

      assert has_element?(lv, "#calendar-delete-confirm", "calendar copy of a booking")
      refute has_element?(lv, "#calendar-delete-quietly")
      refute_enqueued(worker: CalendarEventDeleteWorker)

      lv |> element("#calendar-delete-notify") |> render_click()

      assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"notify_attendees" => false})
      refute has_element?(lv, "#calendar-undo")
    end

    test "the copy of a cancelled booking is deleted like a plain event, with Undo", %{
      conn: conn,
      integration: integration
    } do
      copy = event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30)

      insert(:meeting,
        calendar_integration_id: integration.id,
        calendar_uid: copy.uid,
        attendee_email: "guest@example.com",
        status: "cancelled"
      )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas(lv, "calendar:delete", %{"id" => "event-#{copy.id}"})

      refute has_element?(lv, "#calendar-delete-confirm")
      assert has_element?(lv, "#calendar-undo")
    end

    test "a confirmation answer that is neither true nor false deletes nothing", %{
      conn: conn,
      integration: integration
    } do
      call =
        event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
          attendees: [%{"email" => "ada@example.com"}]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas(lv, "calendar:delete", %{"id" => "event-#{call.id}"})

      canvas(lv, "calendar:confirm_delete", %{"notify" => "maybe"})

      refute_enqueued(worker: CalendarEventDeleteWorker)
      assert has_element?(lv, "#calendar-delete-confirm")
    end
  end

  describe "client input is never trusted" do
    test "malformed payloads change nothing and crash nothing", %{
      conn: conn,
      integration: integration
    } do
      call =
        event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
          attendees: [%{"email" => "ada@example.com"}]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      for {name, params} <- [
            {"calendar:delete", %{}},
            {"calendar:delete", %{"id" => 7}},
            {"calendar:delete", %{"id" => ["event-#{call.id}"]}},
            {"calendar:delete", %{"id" => "event-0"}},
            {"calendar:confirm_delete", %{}},
            {"calendar:confirm_delete", %{"notify" => "true"}},
            {"calendar:choose_scope", %{"scope" => "series"}},
            {"calendar:choose_scope", %{"scope" => 3}},
            {"calendar:cancel_delete", %{}}
          ] do
        canvas(lv, name, params)
      end

      assert Process.alive?(lv.pid)
      refute_enqueued(worker: CalendarEventDeleteWorker)
    end

    test "a scope a delete prompt does not offer is ignored", %{
      conn: conn,
      integration: integration
    } do
      monday =
        event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
          recurring_event_id: "standup-series"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas(lv, "calendar:delete", %{"id" => "event-#{monday.id}"})

      canvas(lv, "calendar:choose_scope", %{"scope" => "following"})

      assert has_element?(lv, "#calendar-scope-series")
      refute_enqueued(worker: CalendarEventDeleteWorker)
    end

    test "another organiser's event id deletes nothing", %{conn: conn} = context do
      stranger = owner(ConnTest.build_conn())
      theirs = event(stranger.integration, "work", "Private", ~U[2026-10-15 10:00:00Z])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas(lv, "calendar:delete", %{"id" => "event-#{theirs.id}"})

      refute_enqueued(worker: CalendarEventDeleteWorker)
      assert context.user.id != stranger.user.id
    end
  end
end
