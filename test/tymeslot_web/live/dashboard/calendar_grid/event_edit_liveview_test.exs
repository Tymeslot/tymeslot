defmodule TymeslotWeb.Dashboard.CalendarGrid.EventEditLiveViewTest do
  @moduledoc """
  Editing an event from the calendar grid, end to end: the organiser's edit in
  the detail modal, the provider write it becomes, and what the grid shows
  once that write has answered.

  The provider write runs in a supervised Task and reaches the suite-wide
  `Tymeslot.CalendarMock`. Each expectation reports the Task's pid, so a test
  can wait for the Task to finish instead of sleeping.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  # The provider write runs in a Task; allow for a busy test machine.
  @task_timeout 5_000

  @attendees [%{"email" => "guest@example.com", "name" => "Guest", "status" => "accepted"}]
  @rrule "FREQ=WEEKLY;BYDAY=MO"

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    integration = insert(:calendar_integration, user: user, is_active: true)
    {:ok, conn: conn, user: user, integration: integration}
  end

  describe "renaming an event" do
    test "keeps its attendees, reminders, repeat rule and colour on the calendar", %{
      conn: conn,
      integration: integration
    } do
      event = insert_timed_event(integration)
      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      payload = await_provider_update(lv)
      assert payload.summary == "Renamed"
      assert payload.attendees == @attendees
      assert [%{minutes_before: 15}] = payload.reminders
      assert payload.recurrence_rule == @rrule
      assert payload.colour == "tomato"
    end

    test "keeps the event's series link and etag in the cache", %{
      conn: conn,
      integration: integration
    } do
      event = insert_timed_event(integration)
      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      await_provider_update(lv)

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.summary == "Renamed"
      assert row.recurring_event_id == "series-1"
      assert row.etag == "\"etag-1\""
      assert row.attendees == @attendees
    end
  end

  describe "toggling an event to all-day" do
    test "sends date-only timing and keeps attendees and the repeat rule", %{
      conn: conn,
      integration: integration
    } do
      event = insert_timed_event(integration)
      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()
      lv |> element("#calendar-grid") |> render_hook("toggle_event_all_day", %{})

      payload = await_provider_update(lv)
      today = Date.utc_today()
      assert payload.start_time == today
      assert payload.end_time == Date.add(today, 1)
      assert payload.attendees == @attendees
      assert payload.recurrence_rule == @rrule
    end
  end

  describe "adding an attendee to an all-day event" do
    test "sends the event's dates rather than empty times", %{
      conn: conn,
      integration: integration
    } do
      today = Date.utc_today()

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "Company Offsite",
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: today,
          end_date: Date.add(today, 1),
          attendees: []
        )

      expect_provider_update(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#allday-event-#{event.id}") |> render_click()

      lv
      |> element("form[phx-submit=add_event_attendee]")
      |> render_submit(%{"email" => "colleague@example.com"})

      payload = await_provider_update(lv)
      assert payload.start_time == today
      assert payload.end_time == Date.add(today, 1)
      assert [%{"email" => "colleague@example.com"}] = payload.attendees
    end
  end

  describe "an edit the calendar could not accept" do
    test "a write queued for retry keeps the edit and says it will sync", %{
      conn: conn,
      user: user
    } do
      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "caldav",
          calendar_paths: ["/cal/"]
        )

      event = insert_timed_event(integration, %{provider: "caldav"})
      expect_provider_update({:error, :server_error})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      await_provider_update(lv)
      html = render(lv)

      assert html =~ "will sync"
      refute html =~ "changes reverted"
      assert html =~ "Renamed"

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.sync_state == "locally_modified"
      assert row.summary == "Renamed"
    end

    test "a write that cannot be retried is reverted and never queued", %{
      conn: conn,
      user: user
    } do
      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "caldav",
          calendar_paths: ["/cal/"]
        )

      event = insert_timed_event(integration, %{provider: "caldav"})
      expect_provider_update({:error, :unauthorized})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      await_provider_update(lv)
      html = render(lv)

      assert html =~ "Failed to update event - changes reverted"
      refute html =~ "Renamed"

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.sync_state == "synced"
    end

    test "a write that crashes is reverted instead of left on screen", %{
      conn: conn,
      integration: integration
    } do
      event = insert_timed_event(integration)
      test_pid = self()

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context ->
        send(test_pid, {:provider_update, self(), nil})
        raise "provider exploded"
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Renamed"})

      await_provider_update(lv)
      html = render(lv)

      assert html =~ "Failed to update event - changes reverted"
      refute html =~ "Renamed"
    end
  end

  defp insert_timed_event(integration, attrs \\ %{}) do
    today = Date.utc_today()

    defaults = %{
      calendar_integration: integration,
      summary: "Weekly sync",
      start_at: DateTime.new!(today, ~T[10:00:00.000000], "Etc/UTC"),
      end_at: DateTime.new!(today, ~T[11:00:00.000000], "Etc/UTC"),
      all_day: false,
      attendees: @attendees,
      reminders: [%{"method" => "popup", "minutes_before" => 15}],
      recurrence_rule: @rrule,
      colour: "tomato",
      recurring_event_id: "series-1",
      etag: "\"etag-1\"",
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp expect_provider_update(result) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:provider_update, self(), payload})
      result
    end)
  end

  # Waits for the Task that made the provider write to exit, then renders
  # twice: once for the LiveView to handle the Task's result message, once
  # for the grid component to apply what that handler sent it.
  defp await_provider_update(lv) do
    assert_receive {:provider_update, task_pid, payload}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    payload
  end
end
