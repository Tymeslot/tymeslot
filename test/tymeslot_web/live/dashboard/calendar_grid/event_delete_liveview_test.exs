defmodule TymeslotWeb.Dashboard.CalendarGrid.EventDeleteLiveViewTest do
  @moduledoc """
  Deleting an event from the detail modal, end to end: the organiser asks to
  delete, confirms, the provider delete runs in the background, and the grid,
  the cache and any booking the event belonged to reflect the answer.

  The provider delete runs in a supervised Task and reaches the suite-wide
  `Tymeslot.CalendarMock`. The stub reports its call with the Task's pid, so a
  test can wait for the Task to finish instead of sleeping.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  # The provider delete runs in a Task; allow for a busy test machine.
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

  describe "deleting an event" do
    test "removes it from the calendar, the cache and the grid", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      event = insert_event(integration)
      stub_delete(:ok)

      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Quarterly Planning"

      confirm_delete(lv, event)

      assert {:delete, uid, context, opts} = await_delete(lv)
      assert {uid, context} == {event.uid, {integration.id, user.id}}
      assert opts == [provider_event_id: event.provider_event_id]

      html = render(lv)
      assert html =~ "Event deleted."
      refute html =~ "Quarterly Planning"

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
    end

    test "cancels the booking the event belongs to", %{conn: conn, integration: integration} do
      TestMocks.setup_email_mocks()
      event = insert_event(integration)

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: event.provider_event_id,
          attendee_email: "guest@example.com"
        )

      stub_delete(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      confirm_delete(lv, event)
      await_delete(lv)

      assert render(lv) =~ "Event and linked meeting cancelled."
      {:ok, cancelled} = MeetingQueries.get_meeting(meeting.id)
      assert cancelled.status == "cancelled"
    end

    test "a delete the calendar could not take is queued and says so", %{
      conn: conn,
      integration: integration
    } do
      event = insert_event(integration)
      stub_delete({:error, :network_error})

      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Quarterly Planning"

      confirm_delete(lv, event)
      await_delete(lv)

      html = render(lv)
      assert html =~ "Delete failed - queued to retry on next sync"

      # The organiser is told the delete is queued, so the event must leave the
      # grid with the flash rather than linger until the next reload.
      refute html =~ "Quarterly Planning"

      # The queue marker has to survive: the row stays `locally_deleted` until
      # the replay succeeds, or the next sync brings the event back.
      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.sync_state == "locally_deleted"
    end

    test "a delete the calendar refused for good is reported and the event stays", %{
      conn: conn,
      integration: integration
    } do
      event = insert_event(integration)
      stub_delete({:error, :unauthorized})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      confirm_delete(lv, event)
      await_delete(lv)

      html = render(lv)
      assert html =~ "Failed to delete event"
      refute html =~ "queued to retry"
      assert html =~ "Quarterly Planning"

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.sync_state == "synced"
    end
  end

  describe "deleting an occurrence of a Google series" do
    setup %{user: user} do
      google = insert(:calendar_integration, user: user, provider: "google")

      %{
        google: google,
        first: insert_event(google, google_occurrence("series-1", "T100000Z", ~T[10:00:00])),
        second: insert_event(google, google_occurrence("series-1", "T140000Z", ~T[14:00:00]))
      }
    end

    test "offers this event or all events", %{conn: conn, first: first} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      request_delete(lv, first)

      html = render(lv)
      assert html =~ "Delete recurring event"
      assert has_element?(lv, ~s(#confirm-delete-event-modal [phx-value-scope="occurrence"]))
      assert has_element?(lv, ~s(#confirm-delete-event-modal [phx-value-scope="series"]))
    end

    test "\"Delete this event\" deletes the occurrence by its own id and keeps the rest", %{
      conn: conn,
      google: google,
      first: first,
      second: second
    } do
      stub_delete(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      request_delete(lv, first)
      confirm_scope(lv, "occurrence")

      assert {:delete, _uid, _context, opts} = await_delete(lv)
      assert opts[:provider_event_id] == first.provider_event_id

      html = render(lv)
      assert html =~ "Event deleted."
      refute has_element?(lv, "[id^='event-#{first.id}-']")
      assert has_element?(lv, "[id^='event-#{second.id}-']")
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(google.id, second.uid)
    end

    test "\"Delete all events\" deletes the series by its master's id", %{
      conn: conn,
      google: google,
      first: first,
      second: second
    } do
      stub_delete(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      request_delete(lv, first)
      confirm_scope(lv, "series")

      assert {:delete, _uid, _context, opts} = await_delete(lv)
      assert opts[:provider_event_id] == "series-1"

      assert render(lv) =~ "Recurring event deleted."
      refute has_element?(lv, "[id^='event-#{first.id}-']")
      refute has_element?(lv, "[id^='event-#{second.id}-']")

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(google.id, second.uid)
    end

    test "keeps the scope through the attendee notification prompt", %{
      conn: conn,
      google: google,
      second: second
    } do
      attendee = %{"email" => "guest@example.com", "name" => "Guest"}
      occurrence = google_occurrence("series-1", "T160000Z", ~T[16:00:00])
      event = insert_event(google, Map.put(occurrence, :attendees, [attendee]))

      stub_delete(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      request_delete(lv, event)
      confirm_scope(lv, "series")

      assert render(lv) =~ "notify-prompt-modal"

      lv
      |> element("#calendar-grid")
      |> render_hook("notify_prompt_confirm", %{})

      assert {:delete, _uid, _context, opts} = await_delete(lv)
      assert opts[:provider_event_id] == "series-1"

      assert render(lv) =~ "Recurring event deleted. Attendees have been notified."
      refute has_element?(lv, "[id^='event-#{second.id}-']")
    end
  end

  describe "deleting an event that is not in a series" do
    test "confirms without asking for a scope", %{conn: conn, integration: integration} do
      event = insert_event(integration)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      request_delete(lv, event)

      assert render(lv) =~ "confirm-delete-event-modal"
      refute has_element?(lv, "#confirm-delete-event-modal [phx-value-scope]")
    end
  end

  describe "deleting an occurrence of an Exchange series" do
    # No provider stub: under `verify_on_exit!` a delete that reached the
    # calendar would fail the test as an unexpected call.
    test "is refused before the confirmation, and the series stays", %{
      conn: conn,
      user: user
    } do
      exchange = insert(:calendar_integration, user: user, provider: "exchange")

      event =
        insert_event(exchange, %{
          provider: "exchange",
          provider_calendar_id: "calendar",
          provider_event_id: "AAMkAD-occurrence",
          provider_metadata: %{"calendar_item_type" => "Occurrence"}
        })

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      request_delete(lv, event)

      html = render(lv)
      assert html =~ "Recurring Exchange events cannot be deleted here yet."
      refute html =~ "confirm-delete-event-modal"

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(exchange.id, event.uid)
      assert row.sync_state == "synced"
    end
  end

  defp insert_event(integration, attrs \\ %{}) do
    today = Date.utc_today()

    defaults = %{
      calendar_integration: integration,
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/quarterly-planning-#{System.unique_integer([:positive])}.ics",
      summary: "Quarterly Planning",
      start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
      end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  # An expanded Google occurrence on today's grid: an id of its own, naming
  # its master's.
  defp google_occurrence(series_id, stamp, time) do
    today = Date.utc_today()
    start_at = DateTime.new!(today, time, "Etc/UTC")

    %{
      provider: "google",
      uid: "#{series_id}@google.com_#{stamp}",
      provider_calendar_id: "primary",
      provider_event_id: "#{series_id}_#{stamp}",
      recurring_event_id: series_id,
      summary: "Weekly standup",
      start_at: start_at,
      end_at: DateTime.add(start_at, 30, :minute)
    }
  end

  # Opens the event and asks to delete it.
  defp request_delete(lv, event) do
    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    lv
    |> element("#calendar-grid")
    |> render_hook("request_delete_event", %{})
  end

  # Opens the event, asks to delete it and confirms in the modal.
  defp confirm_delete(lv, event) do
    request_delete(lv, event)
    assert render(lv) =~ "confirm-delete-event-modal"

    lv
    |> element("#calendar-grid")
    |> render_hook("confirm_delete_event", %{})
  end

  # Clicks the modal's button for `scope`, as the organiser would.
  defp confirm_scope(lv, scope) do
    lv
    |> element(~s(#confirm-delete-event-modal [phx-value-scope="#{scope}"]))
    |> render_click()
  end

  defp stub_delete(result) do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :delete_event, fn uid, context, opts ->
      send(test_pid, {:provider_call, self(), {:delete, uid, context, opts}})
      result
    end)
  end

  # Waits for the Task that made the delete to exit, then renders twice: once
  # for the LiveView to handle the Task's result, once for the grid to apply
  # what it was sent.
  defp await_delete(lv) do
    assert_receive {:provider_call, task_pid, call}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    call
  end
end
