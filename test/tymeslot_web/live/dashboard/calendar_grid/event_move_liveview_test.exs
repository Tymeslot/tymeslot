defmodule TymeslotWeb.Dashboard.CalendarGrid.EventMoveLiveViewTest do
  @moduledoc """
  Moving an event to another calendar from the detail modal, end to end: the
  organiser picks a calendar, the provider writes the move becomes, and what
  the grid and the cache show once those writes have answered.

  The provider writes run in a supervised Task and reach the suite-wide
  `Tymeslot.CalendarMock`. Every stub reports its call with the Task's pid, in
  the order the calls were made, so a test can wait for the Task to finish
  instead of sleeping.
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

  # The provider writes run in a Task; allow for a busy test machine.
  @task_timeout 5_000

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)

    source = insert(:calendar_integration, user: user, calendar_paths: ["/cal/source/"])
    destination = insert(:calendar_integration, user: user, calendar_paths: ["/cal/destination/"])

    {:ok, conn: conn, user: user, source: source, destination: destination}
  end

  describe "moving an all-day event" do
    test "files it on the new calendar and drops the original", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      event = insert_all_day_event(source)
      stub_create(&created_when_dated/1)
      stub_delete(:ok)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      move(lv, event, destination)

      assert [{:create, payload, _create_context}, {:delete, _uid, _delete_context}] =
               await_move(lv, 2)

      today = Date.utc_today()
      refute render(lv) =~ "Could not move"

      assert {:ok, moved} = ProviderCalendarEventQueries.get_by_uid(destination.id, payload.uid)

      assert {moved.all_day, moved.start_date, moved.end_date} ==
               {true, today, Date.add(today, 1)}

      assert moved.provider_calendar_id == "/cal/destination/"
      assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
    end
  end

  describe "a move the new calendar refuses" do
    test "leaves the original in place and says so", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      event = insert_all_day_event(source)
      stub_create(fn _payload -> {:error, :server_error} end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      move(lv, event, destination)

      assert [{:create, _payload, _context}] = await_move(lv, 1)

      html = render(lv)
      assert html =~ "Could not move the event. It is still on its original calendar."
      assert html =~ "Company Offsite"

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
      assert row.sync_state == "synced"
    end
  end

  describe "a move whose original could not be removed" do
    test "says the event was copied and the original is still there", %{
      conn: conn,
      user: user,
      destination: destination
    } do
      google = insert(:calendar_integration, user: user, provider: "google")
      event = insert_all_day_event(google, %{provider: "google"})
      stub_create(&created_when_dated/1)
      stub_delete({:error, :not_found})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      move(lv, event, destination)

      assert [{:create, _payload, _context}, {:delete, _uid, _delete_context}] =
               await_move(lv, 2)

      assert render(lv) =~ "the original could not be removed"
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(google.id, event.uid)
    end

    test "on a CalDAV calendar, says the original will be removed on the next sync", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      event = insert_all_day_event(source)
      stub_create(&created_when_dated/1)
      stub_delete({:error, :network_error})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      move(lv, event, destination)

      assert [{:create, _payload, _context}, {:delete, _uid, _delete_context}] =
               await_move(lv, 2)

      assert render(lv) =~ "The original will be removed on the next sync."
      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
      assert row.sync_state == "locally_deleted"
    end
  end

  describe "moving a recurring event" do
    for {kind, attrs} <- [
          series: quote(do: %{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"}),
          occurrence: quote(do: %{recurring_event_id: "series-1"})
        ] do
      test "a #{kind} is refused with a clear message and stays where it is", %{
        conn: conn,
        source: source,
        destination: destination
      } do
        event = insert_all_day_event(source, unquote(attrs))

        {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
        move(lv, event, destination)

        assert render(lv) =~ "Recurring events cannot be moved to another calendar"

        assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(source.id, event.uid)
        assert row.calendar_integration_id == source.id
      end
    end
  end

  defp insert_all_day_event(integration, attrs \\ %{}) do
    today = Date.utc_today()

    defaults = %{
      calendar_integration: integration,
      provider: "caldav",
      summary: "Company Offsite",
      all_day: true,
      start_at: nil,
      end_at: nil,
      start_date: today,
      end_date: Date.add(today, 1),
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  # The event lands in the all-day row, so the modal is opened through the
  # hook the row itself uses.
  defp move(lv, event, destination) do
    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    lv
    |> element("#calendar-grid")
    |> render_hook("update_event_calendar", %{"integration-id" => to_string(destination.id)})
  end

  # Stands in for the adapters' own validation: a provider refuses to create
  # an event with no start, which is what an all-day move used to send.
  defp created_when_dated(%{uid: uid, start_time: %Date{}, end_time: %Date{}}), do: {:ok, uid}
  defp created_when_dated(_payload), do: {:error, :invalid_event_data}

  defp stub_create(answer) do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, context ->
      send(test_pid, {:provider_call, self(), {:create, payload, context}})
      answer.(payload)
    end)
  end

  defp stub_delete(result) do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :delete_event, fn uid, context, _opts ->
      send(test_pid, {:provider_call, self(), {:delete, uid, context}})
      result
    end)
  end

  # Collects `count` provider calls in the order they were made, waits for the
  # Task that made them to exit, then renders twice: once for the LiveView to
  # handle the Task's result, once for the grid to apply what it was sent.
  defp await_move(lv, count) do
    calls =
      for _call <- 1..count do
        assert_receive {:provider_call, task_pid, call}, @task_timeout
        {task_pid, call}
      end

    {task_pid, _call} = hd(calls)
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    Enum.map(calls, fn {_pid, call} -> call end)
  end
end
