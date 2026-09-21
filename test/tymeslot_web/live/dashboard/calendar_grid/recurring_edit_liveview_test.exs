defmodule TymeslotWeb.Dashboard.CalendarGrid.RecurringEditLiveViewTest do
  @moduledoc """
  Editing one occurrence of a repeating event from the grid: dragging it,
  resizing it, re-dating it, renaming it.

  On the CalDAV family the sync expands a series into one cached row per
  occurrence, all sharing the series' href, and the writer patches the master
  VEVENT. A new start written there does not shift the series, it relocates
  every occurrence onto the date the organiser dragged one to: "this Tuesday
  at 11" would move every Tuesday. A rename does the same damage, because the
  payload is the complete event and carries that occurrence's start with it.
  The grid therefore refuses the edit before anything optimistic is drawn and
  before any provider call.

  Google and Outlook address an occurrence by its own id, so theirs still goes
  through — by way of the recurrence prompt, whose copy promises exactly that.
  Both halves are pinned here: a refusal that also caught Google would take a
  working feature away, and a prompt shown on CalDAV would be the bug with a
  dialog in front of it.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  # The provider write runs in a Task; allow for a busy test machine.
  @task_timeout 5_000

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)

    integration =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    {:ok, conn: conn, user: user, integration: integration}
  end

  describe "dragging one occurrence of a CalDAV series" do
    # No `stub`: under `verify_on_exit!` a write that reached the calendar
    # would fail the test as an unexpected call.
    test "is refused, and the occurrence keeps its time", %{
      conn: conn,
      integration: integration
    } do
      event = insert_event(integration, %{recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)

      html = render(lv)
      assert html =~ "Recurring events cannot be edited here yet."
      refute html =~ "recurrence-prompt-modal"

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.start_at == event.start_at
      assert row.end_at == event.end_at
    end

    test "is refused for an occurrence that was already edited on its own", %{
      conn: conn,
      integration: integration
    } do
      # A detached override: no RRULE of its own, named only by the recurrence
      # id the sync keeps in `provider_metadata`. It lives in the series'
      # resource like every other occurrence, and the patcher skips it, so a
      # write against it lands on the master.
      event =
        insert_event(integration, %{
          provider_metadata: %{"recurrence_id" => "20260915T090000"}
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)

      assert render(lv) =~ "Recurring events cannot be edited here yet."

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.start_at == event.start_at
    end

    test "resizing it is refused the same way", %{conn: conn, integration: integration} do
      event = insert_event(integration, %{recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("event_resized", %{
        "event-id" => to_string(event.id),
        "event-date" => Date.to_iso8601(Date.utc_today()),
        "new-end-hour" => "13",
        "new-end-minute" => "0"
      })

      assert render(lv) =~ "Recurring events cannot be edited here yet."

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.end_at == event.end_at
    end

    test "turning it into an all-day event is refused the same way", %{
      conn: conn,
      integration: integration
    } do
      event = insert_event(integration, %{recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("show_event", %{"event-id" => to_string(event.id)})

      lv |> element("#calendar-grid") |> render_hook("toggle_event_all_day", %{})

      assert render(lv) =~ "Recurring events cannot be edited here yet."

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      refute row.all_day
    end
  end

  describe "renaming one occurrence of a CalDAV series" do
    test "is refused, and the occurrence keeps its title", %{
      conn: conn,
      integration: integration
    } do
      event = insert_event(integration, %{recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("show_event", %{"event-id" => to_string(event.id)})

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Daily standup"})

      html = render(lv)
      assert html =~ "Recurring events cannot be edited here yet."
      refute html =~ "Daily standup"

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.summary == "Weekly standup"
    end
  end

  describe "dragging an event the writer can address on its own" do
    test "a one-off CalDAV event still moves", %{conn: conn, integration: integration} do
      event = insert_event(integration)
      stub_update()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)

      assert {:update, payload} = await_update(lv)
      assert DateTime.compare(payload.start_time, at_today(14)) == :eq
      refute render(lv) =~ "Recurring events cannot be edited here yet."

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert DateTime.compare(row.start_at, at_today(14)) == :eq
    end

    test "a Google occurrence is offered the recurrence prompt instead", %{
      conn: conn,
      user: user
    } do
      google = insert(:calendar_integration, user: user, provider: "google")

      event =
        insert_event(google, %{
          provider: "google",
          provider_calendar_id: "primary",
          recurring_event_id: "weekly-standup",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      drop(lv, event, 14)

      html = render(lv)
      assert html =~ "recurrence-prompt-modal"
      assert html =~ "the rest of the series stays as it is"
      refute html =~ "Recurring events cannot be edited here yet."
    end
  end

  defp at_today(hour), do: DateTime.new!(Date.utc_today(), Time.new!(hour, 0, 0), "Etc/UTC")

  defp insert_event(integration, attrs \\ %{}) do
    today = Date.utc_today()

    defaults = %{
      calendar_integration: integration,
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/weekly-standup-#{System.unique_integer([:positive])}.ics",
      summary: "Weekly standup",
      start_at: DateTime.new!(today, ~T[09:00:00], "Etc/UTC"),
      end_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  # Drops the event on today's grid at `hour`, keeping its one-hour length.
  defp drop(lv, event, hour) do
    lv
    |> element("#calendar-grid")
    |> render_hook("event_dropped", %{
      "event-id" => to_string(event.id),
      "new-date" => Date.to_iso8601(Date.utc_today()),
      "new-hour" => to_string(hour),
      "new-minute" => "0",
      "new-end-hour" => to_string(hour + 1),
      "new-end-minute" => "0"
    })
  end

  defp stub_update do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:provider_call, self(), {:update, payload}})
      :ok
    end)
  end

  # Waits for the provider call, for the Task that made it to exit, and then
  # renders so the LiveView handles the Task's result.
  defp await_update(lv) do
    assert_receive {:provider_call, task_pid, call}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    call
  end
end
