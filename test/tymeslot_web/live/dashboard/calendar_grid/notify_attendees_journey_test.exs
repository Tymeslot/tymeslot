defmodule TymeslotWeb.Dashboard.CalendarGrid.NotifyAttendeesJourneyTest do
  @moduledoc """
  The organiser's journey from an edit on the calendar grid to the email an
  attendee receives: rename the event, confirm "notify attendees", let the
  debounced worker run, and deliver the email job it enqueues.

  The event has never been notified, which is the state every event is
  created and synced in, so this is the first edit most organisers make. It
  is all-day, the kind of event whose change email used to raise instead of
  being sent.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :notifications
  @moduletag :emails
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Workers.EmailWorker

  setup %{conn: conn} do
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    integration = insert(:calendar_integration, user: user, is_active: true)
    today = Date.utc_today()

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "caldav",
        summary: "Offsite",
        location: "",
        description: "",
        attendees: [%{"email" => "guest@example.com", "name" => "Guest"}],
        all_day: true,
        start_date: today,
        end_date: Date.add(today, 2),
        start_at: nil,
        end_at: nil,
        last_notified_state: %{}
      )

    {:ok, conn: conn, event: event, today: today}
  end

  test "renaming an all-day event and confirming delivers the attendee its current details", %{
    conn: conn,
    event: event,
    today: today
  } do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :update_event, fn uid, _data, _context ->
      send(test_pid, {:provider_updated, self(), uid})
      :ok
    end)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    # All-day events sit in the banner row, not the time grid.
    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    html =
      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_title", %{"value" => "Team offsite"})

    assert html =~ "notify-prompt-modal"

    # The rename reaches the cached row from a background task; wait for it
    # to finish so the email reads what the organiser saved.
    assert_receive {:provider_updated, task_pid, _uid}, 5_000
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 5_000

    lv |> element("#calendar-grid") |> render_hook("notify_prompt_confirm", %{})

    assert [worker_job] = all_enqueued(worker: Worker)
    assert :ok = perform_job(Worker, worker_job.args)

    assert [email_job] =
             [worker: EmailWorker]
             |> all_enqueued()
             |> Enum.filter(&(&1.args["action"] == "send_event_update_notification"))

    assert :ok = perform_job(EmailWorker, email_job.args)

    assert_received {:email, email}
    assert email.to == [{"", "guest@example.com"}]
    assert email.subject =~ "Team offsite"

    last_day = today |> Date.add(1) |> Calendar.strftime("%B %d, %Y")
    assert email.text_body =~ "Time: All day, until #{last_day}"
    assert email.text_body =~ "Current Details"
    assert email.text_body =~ "Title: Team offsite"
    refute email.text_body =~ "(none)"
  end
end
