defmodule TymeslotWeb.Dashboard.CalendarGrid.TimeChangeNotifyLiveViewTest do
  @moduledoc """
  Telling the attendees about a change of an event's timing made on the grid
  (an inline time edit or a drag): the organiser is asked only once the
  calendar has accepted the write, in the scope they chose for a recurring
  series.

  Asked before, the organiser was told attendees would be notified of a
  change that then failed, or that was cancelled at the recurrence prompt,
  and a change to a whole series was handed to the debounced notification,
  which reads the series' cached rows the write had just dropped, so nobody
  was emailed.
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
  import Tymeslot.TestHelpers.Eventually

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.EmailWorker

  setup :set_mox_global
  setup :verify_on_exit!

  # The provider write runs in a Task; allow for a busy test machine.
  @task_timeout 5_000

  @guest %{"email" => "guest@example.com", "name" => "Guest"}

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

    {:ok, conn: conn, user: user}
  end

  describe "an event outside a series" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: "Planning",
          attendees: [@guest],
          start_at: at_today(9),
          end_at: at_today(10),
          all_day: false
        )

      %{event: event}
    end

    test "an inline time edit asks about the attendees once the calendar took it", %{
      conn: conn,
      event: event
    } do
      stub_provider_update(:ok)
      lv = open(conn, event)

      html = edit_time(lv, 14)
      refute html =~ "notify-prompt-modal"

      await_write()
      eventually(fn -> has_element?(lv, "#notify-prompt-modal") end, timeout: @task_timeout)

      lv |> element("#calendar-grid") |> render_hook("notify_prompt_confirm", %{})

      assert_enqueued(
        worker: Worker,
        args: %{"event_id" => event.id, "kind" => "provider_calendar_event", "action" => "update"}
      )
    end

    test "a drag asks about the attendees once the calendar took it", %{
      conn: conn,
      event: event
    } do
      stub_provider_update(:ok)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html = drop(lv, event, 14)
      refute html =~ "notify-prompt-modal"

      await_write()
      eventually(fn -> has_element?(lv, "#notify-prompt-modal") end, timeout: @task_timeout)
    end

    test "a change the calendar refused asks nothing", %{conn: conn, event: event} do
      stub_provider_update({:error, :unauthorized})
      lv = open(conn, event)

      edit_time(lv, 14)
      await_write()

      eventually(fn -> render(lv) =~ "Failed to update event" end, timeout: @task_timeout)
      refute has_element?(lv, "#notify-prompt-modal")
      refute_enqueued(worker: Worker)
    end
  end

  describe "an occurrence of a Google series" do
    setup %{user: user} do
      swap_env(:calendar_module, Operations)
      swap_env(:google_calendar_api_module, GoogleAPI)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          refresh_token_encrypted: Encryption.encrypt("refresh_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          oauth_scope: "https://www.googleapis.com/auth/calendar"
        )

      stamp = Calendar.strftime(Date.utc_today(), "%Y%m%dT090000Z")

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "google",
          provider_calendar_id: "team-calendar",
          uid: "weekly_#{stamp}",
          provider_event_id: "series1_#{stamp}",
          recurring_event_id: "series1",
          summary: "Weekly sync",
          attendees: [@guest],
          start_at: at_today(9),
          end_at: at_today(10),
          all_day: false,
          timezone: "Etc/UTC",
          sync_state: "synced"
        )

      serve_google_master()
      %{event: event}
    end

    test "moving all events and confirming emails the attendees that every occurrence moved",
         %{conn: conn, event: event} do
      lv = open(conn, event)

      html = edit_time(lv, 14)
      assert html =~ "recurrence-prompt-modal"
      refute html =~ "notify-prompt-modal"

      lv |> element("#recurrence-prompt-modal [phx-value-scope='all']") |> render_click()

      # The master is read, then patched; the series' cached rows are then
      # dropped until a sync brings them back.
      for _request <- 1..2, do: assert_receive({:request, _method, _url}, @task_timeout)
      eventually(fn -> has_element?(lv, "#notify-prompt-modal") end, timeout: @task_timeout)

      lv |> element("#calendar-grid") |> render_hook("notify_prompt_confirm", %{})
      assert render(lv) =~ "Attendees will be notified shortly."

      refute_enqueued(worker: Worker)
      assert [job] = update_jobs()
      assert :ok = perform_job(EmailWorker, job.args)

      assert_received {:email, email}
      assert email.to == [{"", "guest@example.com"}]
      assert email.subject =~ "Weekly sync"
      assert email.text_body =~ "updated every occurrence of a repeating event"
    end

    test "cancelling the recurrence prompt asks nothing and sends nothing", %{
      conn: conn,
      event: event
    } do
      lv = open(conn, event)
      edit_time(lv, 14)

      html = lv |> element("#calendar-grid") |> render_hook("cancel_recurrence_prompt", %{})

      refute html =~ "recurrence-prompt-modal"
      refute html =~ "notify-prompt-modal"
      refute_receive {:request, _method, _url}, 200
      refute_enqueued(worker: Worker)
      assert update_jobs() == []
    end
  end

  defp at_today(hour), do: DateTime.new!(Date.utc_today(), Time.new!(hour, 0, 0), "Etc/UTC")

  defp swap_env(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, key, previous),
        else: Application.delete_env(:tymeslot, key)
    end)
  end

  defp open(conn, event) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    lv
  end

  defp edit_time(lv, hour) do
    today = Date.to_iso8601(Date.utc_today())

    lv
    |> element("#calendar-grid")
    |> render_hook("update_event_time", %{
      "start-date" => today,
      "start-time" => "#{hour}:00",
      "end-date" => today,
      "end-time" => "#{hour + 1}:00"
    })
  end

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

  defp stub_provider_update(result) do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
      send(test_pid, {:provider_updated, self()})
      result
    end)
  end

  # Waits for the Task that wrote the change to exit, so its answer is on
  # its way to the LiveView.
  defp await_write do
    assert_receive {:provider_updated, task_pid}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
  end

  # Answers every Google request with the series' master and records it.
  defp serve_google_master do
    test_pid = self()
    first = Date.utc_today() |> Date.add(-14) |> Date.to_iso8601()

    master = %{
      "id" => "series1",
      "iCalUID" => "series1@google.com",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "#{first}T09:00:00Z", "timeZone" => "Etc/UTC"},
      "end" => %{"dateTime" => "#{first}T10:00:00Z", "timeZone" => "Etc/UTC"},
      "recurrence" => ["RRULE:FREQ=WEEKLY"],
      "attendees" => [%{"email" => "guest@example.com"}]
    }

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, _body, _headers, _opts ->
      send(test_pid, {:request, method, url})
      {:ok, %Req.Response{status: 200, body: Jason.encode!(master)}}
    end)
  end

  defp update_jobs do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.filter(&(&1.args["action"] == "send_event_update_notification"))
  end
end
