defmodule TymeslotWeb.Dashboard.CalendarGrid.DeleteNotifyPromptTest do
  @moduledoc """
  Task 18 — asserts that the delete flow opens the notify-prompt modal when the
  event has attendees, and that confirming the prompt enqueues a cancellation
  Worker job while cancelling dispatches the delete without notifying.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.AttendeeNotifications.Worker

  setup :verify_on_exit!

  # The provider delete runs in a Task; allow for a busy test machine.
  @task_timeout 5_000

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)

    integration = insert(:calendar_integration, user: user, is_active: true)

    test_pid = self()

    stub(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
      send(test_pid, {:provider_delete, self()})
      :ok
    end)

    {:ok, conn: conn, user: user, integration: integration}
  end

  defp insert_event_with_attendees(integration, attendees) do
    insert(
      :provider_calendar_event,
      calendar_integration: integration,
      summary: "Cancel Me",
      location: "",
      description: "",
      attendees: attendees,
      start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
      end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
      all_day: false,
      synced_at: DateTime.utc_now(:second)
    )
  end

  describe "delete flow with attendees" do
    test "confirming the notify prompt dispatches delete and enqueues CANCEL", %{
      conn: conn,
      integration: integration
    } do
      event =
        insert_event_with_attendees(integration, [
          %{"email" => "guest@example.com", "name" => "Guest"}
        ])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("request_delete_event", %{})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("confirm_delete_event", %{})

      assert html =~ "notify-prompt-modal"
      assert html =~ "Send cancellation?"
      refute html =~ "confirm-delete-event-modal"

      lv
      |> element("#calendar-grid")
      |> render_hook("notify_prompt_confirm", %{})

      assert_enqueued(
        worker: Worker,
        args: %{
          "event_id" => event.id,
          "kind" => "provider_calendar_event",
          "action" => "delete"
        }
      )

      # Simulate successful delete completion.
      await_delete(lv)
      html = render(lv)
      assert html =~ "Event deleted. Attendees have been notified."
      refute html =~ "Cancel Me"
    end

    test "cancelling the notify prompt dispatches delete without notifying", %{
      conn: conn,
      integration: integration
    } do
      event =
        insert_event_with_attendees(integration, [
          %{"email" => "guest@example.com", "name" => "Guest"}
        ])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("request_delete_event", %{})

      lv
      |> element("#calendar-grid")
      |> render_hook("confirm_delete_event", %{})

      lv
      |> element("#calendar-grid")
      |> render_hook("notify_prompt_cancel", %{})

      refute_enqueued(
        worker: Worker,
        args: %{"event_id" => event.id, "action" => "delete"}
      )

      await_delete(lv)
      html = render(lv)
      assert html =~ "Event deleted."
      refute html =~ "Attendees have been notified"
      refute html =~ "Cancel Me"
    end
  end

  describe "delete flow with no attendees" do
    test "skips the notify prompt and dispatches delete immediately", %{
      conn: conn,
      integration: integration
    } do
      event = insert_event_with_attendees(integration, [])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("request_delete_event", %{})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("confirm_delete_event", %{})

      refute html =~ "notify-prompt-modal"
      refute html =~ "Send cancellation?"

      refute_enqueued(
        worker: Worker,
        args: %{"event_id" => event.id, "action" => "delete"}
      )

      await_delete(lv)
      html = render(lv)
      assert html =~ "Event deleted."
      refute html =~ "Attendees have been notified"
      refute html =~ "Cancel Me"
    end
  end

  # Waits for the Task running the provider delete to exit, then renders once
  # for the LiveView to handle its result; the caller's render lets the grid
  # apply what it was sent.
  defp await_delete(lv) do
    assert_receive {:provider_delete, task_pid}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
  end
end
