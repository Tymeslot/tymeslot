defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePowerJourneyTest do
  @moduledoc """
  The organiser's journeys through the calendar's power layer: save what
  is shown as a calendar set from the rail and switch with the digit keys,
  the set deciding alone what shows while the organiser's own choices come
  back when it is left, with search leaving out what is hidden; change the
  week start and the weekends and see the window reload; turn focus mode on
  and off and see the dashboard menu's marker follow, from
  the first paint after a reload too; and import an `.ics` file into a
  chosen calendar.

  The hook's keys are client side, so the test pushes what the hook pushes
  (`calendar:apply_set` to the surface, `calendar:toggle_focus` to the
  dashboard) with the params the hook sends.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarGrid.CalendarSets
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Onboarding

  # The import writes from a background task, so its mock is global.
  setup :set_mox_global
  setup :verify_on_exit!

  @task_timeout 5_000

  @two_events """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  BEGIN:VEVENT\r
  UID:one@example.com\r
  SUMMARY:Dentist\r
  DTSTART:20261105T090000Z\r
  DTEND:20261105T093000Z\r
  END:VEVENT\r
  BEGIN:VEVENT\r
  UID:two@example.com\r
  SUMMARY:Standup\r
  DTSTART:20261102T090000Z\r
  DTEND:20261102T091500Z\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  defp titles(events), do: Enum.map(events, & &1.title)

  defp hook(lv, name, params), do: lv |> element("#calendar-canvas") |> render_hook(name, params)

  defp ready(lv) do
    hook(lv, "calendar:ready", %{})
    assert_reply(lv, reply)
    reply
  end

  defp open_display_options(lv),
    do: lv |> element("#calendar-display-options > button") |> render_click()

  # The search runs in `start_async`; `render_async/1` waits for it.
  defp search(lv, query) do
    lv |> form("#calendar-command-form", %{"q" => query}) |> render_change()
    render_async(lv)
  end

  # Drops the `calendar:events` pushes received so far, so the next
  # `assert_push_event/3` reads the push the next action causes, not a
  # reload an earlier step caused without asserting it. The message shape
  # is the one `assert_push_event/3` matches.
  defp flush_pushes(%{proxy: {ref, _topic, _pid}} = lv) do
    receive do
      {^ref, {:push_event, "calendar:events", _payload}} -> flush_pushes(lv)
    after
      0 -> :ok
    end
  end

  # The import's result reaches the surface in three hops (the task's
  # result, the runner's `send_update/2`, the reload); one render per hop.
  defp settle(lv), do: Enum.reduce(1..3, nil, fn _hop, _html -> render(lv) end)

  describe "calendar sets and search" do
    test "a set saved from the rail is switched with the digits, and search follows what shows",
         %{conn: conn} do
      %{conn: conn, user: user, integration: integration} = owner(conn)
      event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
      event(integration, "family", "School run", ~U[2026-10-15 07:30:00Z])
      event(integration, "family", "Swim gala", ~U[2026-10-22 16:00:00Z])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-14")
      assert %{events: events} = ready(lv)
      assert ["Design review", "School run"] -- titles(events) == []

      # 1. Hide Family by hand, then save what is shown as the "Work" set.
      flush_pushes(lv)
      lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()
      assert_push_event(lv, "calendar:events", %{reset: true, events: work_only})
      refute "School run" in titles(work_only)

      lv |> element("#calendar-rail-new-set") |> render_click()
      assert has_element?(lv, "#calendar-rail-set-name")
      lv |> form("#calendar-rail-set-form", %{"name" => "Work"}) |> render_submit()

      assert [%{position: 1, name: "Work"}] = CalendarSets.list(user.id)
      assert CalendarPreferencesQueries.get_or_create(user.id).active_calendar_set_id
      assert has_element?(lv, "#calendar-rail-set-1[aria-pressed='true']")
      assert has_element?(lv, "#calendar-filter-chip", "Work set")
      refute has_element?(lv, "#calendar-rail-set-name")

      # 2. 0 leaves the set: the organiser's own choice (Family hidden) is back.
      hook(lv, "calendar:apply_set", %{"position" => 0})
      assert has_element?(lv, "#calendar-rail-set-0[aria-pressed='true']")
      assert has_element?(lv, "#calendar-rail [data-calendar-id='family'][aria-checked='false']")
      assert has_element?(lv, "#calendar-filter-chip", "1 calendar hidden")
      refute has_element?(lv, "#calendar-filter-chip", "Work set")
      refute CalendarPreferencesQueries.get_or_create(user.id).active_calendar_set_id

      # 3. Show all brings Family back by hand.
      flush_pushes(lv)
      lv |> element("#calendar-show-all") |> render_click()
      assert_push_event(lv, "calendar:events", %{reset: true, events: everything})
      assert "School run" in titles(everything)
      refute has_element?(lv, "#calendar-filter-chip")

      # 4. 1 brings the set back. It alone decides, so Family hides again
      #    although the organiser's own choice now shows it.
      flush_pushes(lv)
      hook(lv, "calendar:apply_set", %{"position" => 1})
      assert_push_event(lv, "calendar:events", %{reset: true, events: in_set})
      assert "Design review" in titles(in_set)
      refute "School run" in titles(in_set)
      assert has_element?(lv, "#calendar-rail-set-1[aria-pressed='true']")
      assert has_element?(lv, "#calendar-filter-chip", "Work set")
      assert has_element?(lv, "#calendar-rail [data-calendar-id='family'][aria-checked='false']")

      # 5. Search leaves out what the set hides.
      search(lv, "Swim")
      assert has_element?(lv, "#calendar-command-status", "No matches")
      refute has_element?(lv, "#calendar-command-results [data-command-result]")

      # 6. 0 again: Family shows (the organiser's choice since step 3), the
      #    set itself is untouched, and search finds the event, case aside.
      flush_pushes(lv)
      hook(lv, "calendar:apply_set", %{"position" => 0})
      assert_push_event(lv, "calendar:events", %{reset: true, events: shown})
      assert "School run" in titles(shown)
      assert [%{position: 1, name: "Work"}] = CalendarSets.list(user.id)

      search(lv, "swim")

      assert has_element?(
               lv,
               "#calendar-command-results [data-command-result][data-date='2026-10-22'][data-reveal-ids^='event-']",
               "Swim gala"
             )

      refute has_element?(lv, "#calendar-command-status", "No matches")
    end
  end

  describe "display options and focus mode" do
    test "the week start and weekends reload the window; focus mode marks the layout and is remembered",
         %{conn: conn} do
      %{conn: conn, user: user} = owner(conn)
      # A running tour suspends focus mode, so this organiser has seen it.
      {:ok, _user} = Onboarding.mark_dashboard_tour_seen(user)

      # The Up next strip reads the real clock, not the frozen one.
      start = DateTime.add(DateTime.utc_now(), 3600, :second)

      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        title: "Strategy sync",
        attendee_name: "Grace Hopper",
        start_time: start,
        end_time: DateTime.add(start, 1800, :second),
        status: "confirmed"
      )

      path = ~p"/dashboard/calendar?view=week&date=2026-10-14"
      {:ok, lv, _html} = live(conn, path)
      assert %{range: %{from: "2026-10-05", to: "2026-10-26"}} = ready(lv)

      # 1. The week starts on Sunday: the window moves, the hook drops its cache.
      open_display_options(lv)
      flush_pushes(lv)
      lv |> element("#calendar-week-start-sunday") |> render_click()

      assert_push_event(lv, "calendar:events", %{
        reset: true,
        view: "week",
        range: %{from: "2026-10-04", to: "2026-10-25"},
        settings: %{week_start: "sunday"}
      })

      assert CalendarPreferencesQueries.get_or_create(user.id).week_start_day == "sunday"

      # 2. Weekends off: the window reloads with the setting the hook draws by.
      lv |> element("#calendar-weekends") |> render_click()
      assert_push_event(lv, "calendar:events", %{reset: true, settings: %{show_weekends: false}})
      refute CalendarPreferencesQueries.get_or_create(user.id).show_weekends

      # 3. The strips sit above the calendar.
      assert has_element?(lv, "[data-testid='up-next-strip']", "Strategy sync")
      assert has_element?(lv, "[data-testid='onboarding-checklist']")
      refute has_element?(lv, "#dashboard-root[data-calendar-focus]")

      # 4. Focus mode from the toolbar: the layout's marker, saved. The strips
      #    stay in the page; the stylesheet hides them from the lg breakpoint.
      lv |> element("#calendar-focus-toggle") |> render_click()
      assert has_element?(lv, "#dashboard-root[data-calendar-focus]")
      assert has_element?(lv, "#calendar-focus-toggle[aria-pressed='true']")
      assert has_element?(lv, "#calendar-strips [data-testid='up-next-strip']")
      assert CalendarPreferencesQueries.get_or_create(user.id).focus_mode

      # 5. A reload paints focus mode from the first byte, so the menu never flashes.
      dead = conn |> get(path) |> html_response(200)
      assert dead =~ ~r/id="dashboard-root"[^>]*data-calendar-focus/

      # 6. F (the hook's push to the dashboard) leaves it again.
      {:ok, reopened, _html} = live(conn, path)
      assert has_element?(reopened, "#dashboard-root[data-calendar-focus]")
      render_hook(reopened, "calendar:toggle_focus", %{})
      refute has_element?(reopened, "#dashboard-root[data-calendar-focus]")
      assert has_element?(reopened, "#calendar-focus-toggle[aria-pressed='false']")
      assert has_element?(reopened, "[data-testid='up-next-strip']", "Strategy sync")
      refute CalendarPreferencesQueries.get_or_create(user.id).focus_mode
    end
  end

  describe "ICS import" do
    test "an .ics file is imported into the chosen calendar and the week reloads", %{conn: conn} do
      %{conn: conn, user: user, integration: integration} = owner(conn)
      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, 2, fn data, context ->
        send(test_pid, {:written, data, context, self()})
        {:ok, CreatedEvent.new(data.uid)}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-11-02")
      ready(lv)

      # 1. Display options open the import.
      open_display_options(lv)
      lv |> element("#calendar-import-ics") |> render_click()
      assert has_element?(lv, "#calendar-import")

      # 2. The file is read and summarised.
      lv
      |> file_input("#calendar-ics-upload", :ics_file, [
        %{name: "plans.ics", content: @two_events, type: "text/calendar"}
      ])
      |> render_upload("plans.ics")

      render_async(lv)

      assert lv |> element("[data-testid='calendar-import-summary']") |> render() =~
               "Found 2 events."

      # 3. Family is chosen in the picker, and the import starts.
      lv
      |> form("#calendar-import-calendar")
      |> render_change(%{"calendar" => "#{integration.id}:family"})

      flush_pushes(lv)
      lv |> element("#calendar-import-start") |> render_click()

      assert_receive {:written, %{summary: "Dentist", calendar_id: "family"}, context, task},
                     @task_timeout

      assert_receive {:written, %{summary: "Standup", calendar_id: "family"}, ^context, ^task},
                     @task_timeout

      assert context == {integration.id, user.id}
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}, @task_timeout

      # 4. The result is told and the week reloads.
      settle(lv)
      assert has_element?(lv, "#calendar-toast", "Imported 2 events.")
      assert_push_event(lv, "calendar:events", %{reset: true})
    end
  end
end
