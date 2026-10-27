defmodule TymeslotWeb.Dashboard.CalendarGrid.QueuedEditNotifyLiveViewTest do
  @moduledoc """
  Telling the guests about an edit made on the grid while the CalDAV server
  could not be reached, which is saved and replayed on a later sync: guests
  added or removed are emailed, and the organiser is asked about a time
  change, but nothing is sent until the replay has reached the calendar.

  Before, the queue told guests only about a write the provider accepted at
  once, and nothing told them after the replay, so an added guest was never
  invited, a removed one never told, and the organiser never asked.

  Not async: the emails are scheduled from processes of the grid's own, and
  the replay goes through the shared HTTP stub.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :notifications
  @moduletag :live
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarGridWriteHelpers

  alias Ecto.Changeset
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Meetings.AttendeeNotifications.MembershipWorker
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  @write_timeout 5_000

  @client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/cal/"],
    provider: :caldav
  }

  setup :hold_writes

  setup %{integration: integration} do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)

    integration =
      integration
      |> Changeset.change(provider: "caldav", calendar_paths: ["/cal/"])
      |> Repo.update!()

    today = Date.utc_today()

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "caldav",
        provider_calendar_id: "/cal/",
        summary: "Planning",
        start_at: DateTime.new!(today, ~T[14:00:00], "Etc/UTC"),
        end_at: DateTime.new!(today, ~T[15:00:00], "Etc/UTC"),
        all_day: false,
        attendees: [%{"email" => "guest@example.com", "name" => "Guest"}]
      )

    {:ok, integration: integration, event: event}
  end

  describe "a guest added while the calendar is unreachable" do
    test "is invited once, after the replay", %{
      conn: conn,
      event: event,
      integration: integration
    } do
      lv = open_event(conn, event)
      add(lv, "new@example.com")
      unreachable()

      eventually(
        fn ->
          assert render(lv) =~
                   "Attendee added. They will be invited once the change has synced to your calendar."
        end,
        timeout: @write_timeout
      )

      assert invitations() == []
      assert {:snooze, _seconds} = run_membership_job()
      assert invitations() == []

      replay(integration)
      assert :ok = run_membership_job()

      assert [%{"attendee_email" => "new@example.com", "method" => "request"}] = invitations()
    end

    test "and removed again before the replay hears nothing", %{
      conn: conn,
      event: event,
      integration: integration
    } do
      lv = open_event(conn, event)
      add(lv, "new@example.com")
      unreachable()
      settled(lv)

      remove(lv, "new@example.com")
      unreachable()
      settled(lv)

      assert [_one] = all_enqueued(worker: MembershipWorker)

      replay(integration)
      assert :ok = run_membership_job()
      assert invitations() == []
    end
  end

  describe "a guest removed while the calendar is unreachable" do
    test "is told once, after the replay", %{conn: conn, event: event, integration: integration} do
      lv = open_event(conn, event)
      remove(lv, "guest@example.com")
      unreachable()

      eventually(
        fn ->
          assert render(lv) =~
                   "Attendee removed. They will be notified once the change has synced to your calendar."
        end,
        timeout: @write_timeout
      )

      assert invitations() == []

      replay(integration)
      assert :ok = run_membership_job()

      assert [%{"attendee_email" => "guest@example.com", "method" => "cancel"}] = invitations()
    end
  end

  describe "a time change while the calendar is unreachable" do
    test "asks the organiser at once, and tells the attendees only after the replay", %{
      conn: conn,
      event: event,
      integration: integration
    } do
      lv = open_event(conn, event)
      edit_time(lv, 16)
      unreachable()

      eventually(fn -> assert has_element?(lv, "#notify-prompt-modal") end,
        timeout: @write_timeout
      )

      lv |> element("#calendar-grid") |> render_hook("notify_prompt_confirm", %{})

      assert [job] = all_enqueued(worker: Worker)
      assert {:snooze, _seconds} = perform_job(Worker, job.args)
      assert updates() == []

      replay(integration)
      assert :ok = perform_job(Worker, job.args)

      assert [%{"attendee_emails" => ["guest@example.com"]}] = updates()
    end
  end

  # The held provider write answers as a server that cannot be reached.
  defp unreachable do
    assert_receive {:write_started, write, _uid, _payload}, @write_timeout
    answer(write, {:error, :network_error})
  end

  defp replay(integration) do
    ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 204, "") end)
    assert :ok = OfflineQueue.flush(integration, @client)
  end

  defp run_membership_job do
    assert [job] = all_enqueued(worker: MembershipWorker)
    perform_job(MembershipWorker, job.args)
  end

  defp add(lv, email),
    do: lv |> element("#calendar-grid") |> render_hook("add_event_attendee", %{"email" => email})

  defp remove(lv, email) do
    lv
    |> element("#calendar-grid")
    |> render_hook("request_remove_attendee", %{"email" => email})

    lv |> element("#calendar-grid") |> render_hook("confirm_remove_attendee", %{})
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

  defp invitations, do: email_jobs("send_calendar_invitation")

  defp updates, do: email_jobs("send_event_update_notification")

  defp email_jobs(action) do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.map(& &1.args)
    |> Enum.filter(&(&1["action"] == action))
  end
end
