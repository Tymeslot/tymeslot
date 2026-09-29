defmodule TymeslotWeb.Dashboard.CalendarGrid.DeleteNotifyPromptTest do
  @moduledoc """
  The delete flow opens the notify prompt when the event has attendees.
  Confirming it deletes the event and, once the calendar has deleted it,
  delivers each attendee a cancellation; cancelling it deletes without
  notifying. A delete that fails notifies nobody and says nothing about
  attendees having been notified.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  # The provider delete runs in a Task; allow for a busy test machine.
  @task_timeout 5_000

  setup %{conn: conn} do
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

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
    test "confirming the notify prompt deletes the event and delivers the cancellation", %{
      conn: conn,
      integration: integration
    } do
      event =
        insert_event_with_attendees(integration, [
          %{"email" => "guest@example.com", "name" => "Guest"},
          %{"email" => "second@example.com", "name" => "Second"}
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

      await_delete(lv)
      html = render(lv)
      assert html =~ "Event deleted. Attendees have been notified."
      refute html =~ "Cancel Me"

      # The cached row is gone by now, and the cancellation still goes out.
      refute Repo.get(ProviderCalendarEventSchema, event.id)
      refute_enqueued(worker: Worker)

      delivered =
        for job <- cancellation_jobs() do
          assert :ok = perform_job(EmailWorker, job.args)
          assert_received {:email, email}
          assert email.subject =~ "Cancelled - Cancel Me"
          email.to
        end

      assert Enum.sort(delivered) == [[{"", "guest@example.com"}], [{"", "second@example.com"}]]
    end

    test "a delete queued for the next sync notifies nobody and says so", %{
      conn: conn,
      user: user
    } do
      # A CalDAV calendar with a path has the offline queue.
      integration =
        insert(:calendar_integration, user: user, is_active: true, calendar_paths: ["/cal/"])

      stub_failing_delete({:error, :network_error})
      html = confirm_notified_delete(conn, integration)

      assert html =~ "queued to retry on next sync. Attendees have not been notified."
      refute html =~ "Attendees have been notified"
      assert cancellation_jobs() == []
      refute_enqueued(worker: Worker)
    end

    test "a delete the calendar refused notifies nobody", %{
      conn: conn,
      integration: integration
    } do
      stub_failing_delete({:error, :unauthorized})
      html = confirm_notified_delete(conn, integration)

      assert html =~ "Failed to delete event"
      refute html =~ "Attendees have been notified"
      assert cancellation_jobs() == []
      refute_enqueued(worker: Worker)
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

      await_delete(lv)
      html = render(lv)
      assert html =~ "Event deleted."
      refute html =~ "Attendees have been notified"
      refute html =~ "Cancel Me"
      assert cancellation_jobs() == []
      refute_enqueued(worker: Worker, args: %{"event_id" => event.id})
    end
  end

  describe "delete flow for an event someone else organises" do
    # The user is a guest: the delete takes the event off their calendar, and
    # a cancellation in their name would tell the organiser and every other
    # guest that it is off.
    test "skips the notify prompt and deletes without telling anyone", %{
      conn: conn,
      integration: integration
    } do
      event =
        integration
        |> insert_event_with_attendees([
          %{"email" => "boss@elsewhere.example", "name" => "Boss"},
          %{"email" => "guest@example.com", "name" => "Guest"}
        ])
        |> Changeset.change(organiser: %{"email" => "boss@elsewhere.example"})
        |> Repo.update!()

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

      await_delete(lv)
      html = render(lv)
      assert html =~ "Event deleted."
      refute html =~ "Attendees have been notified"
      refute html =~ "Cancel Me"
      assert cancellation_jobs() == []
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

  defp stub_failing_delete(result) do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
      send(test_pid, {:provider_delete, self()})
      result
    end)
  end

  # Deletes an event with an attendee through the notify prompt's "send"
  # button and returns the page once the delete has finished.
  defp confirm_notified_delete(conn, integration) do
    event =
      insert_event_with_attendees(integration, [%{"email" => "guest@example.com"}])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("[id^='event-#{event.id}-']") |> render_click()

    for hook <- ["request_delete_event", "confirm_delete_event", "notify_prompt_confirm"] do
      lv |> element("#calendar-grid") |> render_hook(hook, %{})
    end

    await_delete(lv)
    render(lv)
  end

  defp cancellation_jobs do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.filter(
      &(&1.args["action"] == "send_calendar_invitation" and &1.args["method"] == "cancel")
    )
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
