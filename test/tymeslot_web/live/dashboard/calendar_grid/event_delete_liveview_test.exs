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

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      confirm_delete(lv, event)
      await_delete(lv)

      assert render(lv) =~ "Delete failed - queued to retry on next sync"
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

  defp insert_event(integration) do
    today = Date.utc_today()

    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/quarterly-planning-#{System.unique_integer([:positive])}.ics",
      summary: "Quarterly Planning",
      start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
      end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
      all_day: false,
      sync_state: "synced"
    )
  end

  # Opens the event, asks to delete it and confirms in the modal.
  defp confirm_delete(lv, event) do
    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    lv
    |> element("#calendar-grid")
    |> render_hook("request_delete_event", %{})

    assert render(lv) =~ "confirm-delete-event-modal"

    lv
    |> element("#calendar-grid")
    |> render_hook("confirm_delete_event", %{})
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
