defmodule TymeslotWeb.Dashboard.CalendarGrid.NotifyPromptTest do
  @moduledoc """
  Task 16 — asserts that the confirm-notify modal, pending banner, and
  cancel-pending path are wired end-to-end on the calendar dashboard when
  inline edits go through `EditWorkflow.notify_event_updated/3`.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.Worker

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)

    integration = insert(:calendar_integration, user: user, is_active: true)

    event =
      insert(
        :provider_calendar_event,
        calendar_integration: integration,
        summary: "Notify Me",
        location: "",
        description: "",
        attendees: [%{"email" => "guest@example.com", "name" => "Guest"}],
        start_at: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(Date.utc_today(), ~T[11:00:00], "Etc/UTC"),
        all_day: false,
        synced_at: DateTime.utc_now(:second)
      )

    {:ok, conn: conn, user: user, integration: integration, event: event}
  end

  describe "notify-attendees prompt" do
    test "a title edit on an event with attendees opens the prompt modal", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_title", %{"value" => "New Title"})

      assert html =~ "notify-prompt-modal"
      assert html =~ "Notify attendees?"
      refute_enqueued(worker: Worker)
    end

    test "confirming the prompt enqueues a Worker job and dismisses the modal", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "New Title"})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("notify_prompt_confirm", %{})

      refute html =~ "notify-prompt-modal"

      assert_enqueued(
        worker: Worker,
        args: %{
          "event_id" => event.id,
          "kind" => "provider_calendar_event",
          "action" => "update"
        }
      )
    end

    test "cancelling the prompt dismisses the modal and enqueues nothing", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "New Title"})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("notify_prompt_cancel", %{})

      refute html =~ "notify-prompt-modal"
      refute_enqueued(worker: Worker)
    end

    test "a second edit while a job is pending does not re-open the modal", %{
      conn: conn,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "First"})

      lv
      |> element("#calendar-grid")
      |> render_hook("notify_prompt_confirm", %{})

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_title", %{"value" => "Second"})

      refute html =~ "notify-prompt-modal"

      jobs = all_enqueued(worker: Worker)

      assert Enum.count(jobs, fn job ->
               job.args["event_id"] == event.id and job.args["action"] == "update"
             end) == 1
    end
  end

  describe "pending-notification banner" do
    test "shows the banner when opening a modal for an event with a pending job", %{
      conn: conn,
      event: event
    } do
      seed_pending_notification(event)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("[id^='event-#{event.id}-']") |> render_click()

      assert html =~ "Attendees will be notified of pending changes"
    end

    test "clicking cancel on the banner clears the pending job", %{
      conn: conn,
      event: event
    } do
      seed_pending_notification(event)
      assert AttendeeNotifications.pending?(event.id)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("[id^='event-#{event.id}-']") |> render_click()

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("cancel_pending_notification", %{})

      refute html =~ "Attendees will be notified of pending changes"
      refute AttendeeNotifications.pending?(event.id)
    end
  end

  defp seed_pending_notification(event) do
    updated = %{event | summary: "#{event.summary} (changed)"}

    {:needs_confirmation, summary} =
      AttendeeNotifications.event_updated(event, updated, event.attendees)

    {:ok, :sent} = AttendeeNotifications.event_updated_confirm(updated, summary, event.attendees)
    :ok
  end
end
