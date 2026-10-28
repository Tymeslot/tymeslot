defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceQueuedGuestEmailTest do
  @moduledoc """
  Telling a guest invited from the side panel, or taken off the event,
  while the CalDAV server could not be reached: the edit is saved and
  replayed on a later sync, and the invitation or cancellation is sent only
  once the replay has reached the calendar.

  Before, the queue told guests only about a write the calendar accepted
  at once, and nothing told them after the replay, so an invited guest was
  never emailed and a removed one never told.

  The calendar mock holds every write until the test answers it. Not
  async: the guardian's emails are scheduled from a process of its own,
  and the replay goes through the shared HTTP stub.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :notifications
  @moduletag :live
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers
  import TymeslotWeb.CalendarSurfaceWriteHelpers

  alias Ecto.Changeset
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Meetings.AttendeeNotifications.MembershipWorker
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

  setup %{conn: conn} do
    context = owner(conn)
    hold_writes()
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)

    integration =
      context.integration
      |> Changeset.change(
        provider: "caldav",
        calendar_paths: ["/cal/"],
        calendar_list: [%{"id" => "/cal/", "name" => "Work", "selected" => true}]
      )
      |> Repo.update!()

    review =
      event(integration, "/cal/", "Design review", ~U[2026-10-14 14:00:00Z], 60,
        provider: "caldav",
        attendees: [%{"email" => "guest@example.com", "display_name" => "Guest"}]
      )

    Map.merge(context, %{integration: integration, review: review})
  end

  describe "inviting a guest while the calendar is unreachable" do
    test "emails them once, after the replay", %{
      conn: conn,
      integration: integration,
      review: review
    } do
      lv = open_event(conn, review)
      invite(lv, "new@example.com")
      unreachable()

      eventually(
        fn ->
          assert has_element?(
                   lv,
                   "#calendar-toast",
                   "Added new@example.com. They will be invited once the change has synced to your calendar."
                 )
        end,
        timeout: @write_timeout
      )

      # Held while the change has not reached the calendar.
      assert invitations() == []
      assert {:snooze, _seconds} = run_membership_job()
      assert invitations() == []

      replay(integration)
      assert :ok = run_membership_job()

      assert [%{"attendee_email" => "new@example.com", "method" => "request"}] = invitations()
    end

    test "emails nobody when they are removed again before the replay", %{
      conn: conn,
      integration: integration,
      review: review
    } do
      lv = open_event(conn, review)
      invite(lv, "new@example.com")
      unreachable()
      settled(lv)

      remove(lv, "new@example.com")
      unreachable()
      settled(lv)

      # The second edit is held in the same job, which compares the guests
      # before the first with those after the second.
      assert [_one] = all_enqueued(worker: MembershipWorker)

      replay(integration)
      assert :ok = run_membership_job()
      assert invitations() == []
    end
  end

  describe "removing a guest while the calendar is unreachable" do
    test "tells them once, after the replay", %{
      conn: conn,
      integration: integration,
      review: review
    } do
      lv = open_event(conn, review)
      remove(lv, "guest@example.com")
      unreachable()

      eventually(
        fn ->
          assert has_element?(
                   lv,
                   "#calendar-toast",
                   "Removed guest@example.com. They will be told once the change has synced to your calendar."
                 )
        end,
        timeout: @write_timeout
      )

      assert invitations() == []

      replay(integration)
      assert :ok = run_membership_job()

      assert [%{"attendee_email" => "guest@example.com", "method" => "cancel"}] = invitations()
    end
  end

  # The held write answers as a server that cannot be reached, so the edit
  # is saved to sync later.
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

  defp invite(lv, email),
    do: lv |> form("#calendar-panel-guest-form") |> render_submit(%{"email" => email})

  defp remove(lv, email) do
    lv
    |> element(~s|#calendar-panel-guests button[phx-value-email="#{email}"]|)
    |> render_click()

    lv |> element("#calendar-remove-guest-confirm") |> render_click()
  end

  defp invitations do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.map(& &1.args)
    |> Enum.filter(&(&1["action"] == "send_calendar_invitation"))
  end
end
