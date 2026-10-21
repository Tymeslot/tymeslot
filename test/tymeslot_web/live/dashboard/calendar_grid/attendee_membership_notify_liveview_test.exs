defmodule TymeslotWeb.Dashboard.CalendarGrid.AttendeeMembershipNotifyLiveViewTest do
  @moduledoc """
  Telling a guest they were added to an event on the grid, or taken off it:
  the invitation or cancellation is sent only once the calendar has accepted
  the write, and the organiser is told what was sent.

  Sent before, a write the calendar then refused left the guest with an
  invitation to an event they were not on, or a cancellation of one they
  were still on, and the organiser with a flash saying the guest was
  invited.

  The calendar mock holds every write until the test answers it. Not
  async: the guardian's emails are scheduled from a process of its own, and
  one test makes the job table refuse inserts.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :notifications
  @moduletag :live
  @moduletag :integration

  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarGridWriteHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  @write_timeout 5_000

  setup :hold_writes

  setup %{integration: integration} do
    today = Date.utc_today()

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Planning",
        start_at: DateTime.new!(today, ~T[14:00:00], "Etc/UTC"),
        end_at: DateTime.new!(today, ~T[15:00:00], "Etc/UTC"),
        all_day: false,
        attendees: [%{"email" => "guest@example.com", "name" => "Guest"}]
      )

    {:ok, event: event}
  end

  describe "adding an attendee" do
    test "invites them once the calendar has accepted the write", %{conn: conn, event: event} do
      lv = open_event(conn, event)
      add(lv, "new@example.com")

      assert_receive {:write_started, write, _uid, %{attendees: attendees}}, @write_timeout
      assert "new@example.com" in Enum.map(attendees, & &1.email)

      # Nothing is sent, nor claimed, while the calendar has not answered.
      refute settled(lv) =~ "Attendee added and invited."
      assert invitations() == []

      answer(write, :ok)

      eventually(fn -> assert render(lv) =~ "Attendee added and invited." end,
        timeout: @write_timeout
      )

      assert [%{"attendee_email" => "new@example.com", "method" => "request"}] = invitations()
    end

    test "invites nobody when the calendar refuses the write", %{conn: conn, event: event} do
      lv = open_event(conn, event)
      add(lv, "new@example.com")

      assert_receive {:write_started, write, _uid, _payload}, @write_timeout
      answer(write, {:error, :unauthorized})

      html = settled(lv)
      assert html =~ "Failed to update event"
      refute html =~ "Attendee added and invited."
      refute html =~ "new@example.com"
      assert invitations() == []
    end

    test "says so when the invitation could not be scheduled", %{conn: conn, event: event} do
      lv = open_event(conn, event)
      add(lv, "new@example.com")

      assert_receive {:write_started, write, _uid, _payload}, @write_timeout
      refuse_email_jobs!()
      answer(write, :ok)

      eventually(
        fn -> assert render(lv) =~ "Attendee added, but their invitation could not be sent." end,
        timeout: @write_timeout
      )

      refute render(lv) =~ "Attendee added and invited."
    end

    # Each write carries its own notification, so the second add cannot
    # overwrite the first's answer.
    test "two quick adds invite both guests", %{conn: conn, event: event} do
      lv = open_event(conn, event)
      add(lv, "first@example.com")
      add(lv, "second@example.com")

      assert_receive {:write_started, first, _uid, _payload}, @write_timeout
      answer(first, :ok)
      assert_receive {:write_started, second, _uid, _payload}, @write_timeout
      answer(second, :ok)
      settled(lv)

      assert invitations() |> Enum.map(& &1["attendee_email"]) |> Enum.sort() ==
               ["first@example.com", "second@example.com"]
    end

    # The second write sends the list the grid showed, first guest included,
    # so the calendar puts them on after all; they are invited then.
    test "a guest whose own write failed is invited once a later write puts them on", %{
      conn: conn,
      event: event
    } do
      lv = open_event(conn, event)
      add(lv, "first@example.com")
      add(lv, "second@example.com")

      assert_receive {:write_started, first, _uid, _payload}, @write_timeout
      answer(first, {:error, :unauthorized})
      settled(lv)
      assert invitations() == []

      assert_receive {:write_started, second, _uid, _payload}, @write_timeout
      answer(second, :ok)
      settled(lv)

      assert invitations() |> Enum.map(& &1["attendee_email"]) |> Enum.sort() ==
               ["first@example.com", "second@example.com"]
    end

    test "still invites them when the LiveView is gone before the calendar answers", %{
      conn: conn,
      event: event
    } do
      lv = open_event(conn, event)
      add(lv, "new@example.com")

      assert_receive {:write_started, write, _uid, _payload}, @write_timeout
      kill(lv)
      answer(write, :ok)

      eventually(fn -> assert [%{"attendee_email" => "new@example.com"}] = invitations() end,
        timeout: @write_timeout
      )
    end
  end

  describe "removing an attendee" do
    test "tells them once the calendar has accepted the write", %{conn: conn, event: event} do
      lv = open_event(conn, event)
      remove(lv, "guest@example.com")

      assert_receive {:write_started, write, _uid, %{attendees: []}}, @write_timeout
      refute settled(lv) =~ "Attendee removed and notified."
      assert invitations() == []

      answer(write, :ok)

      eventually(fn -> assert render(lv) =~ "Attendee removed and notified." end,
        timeout: @write_timeout
      )

      assert [%{"attendee_email" => "guest@example.com", "method" => "cancel"}] = invitations()
    end

    test "tells nobody when the calendar refuses the write", %{conn: conn, event: event} do
      lv = open_event(conn, event)
      remove(lv, "guest@example.com")

      assert_receive {:write_started, write, _uid, _payload}, @write_timeout
      answer(write, {:error, :unauthorized})

      html = settled(lv)
      assert html =~ "Failed to update event"
      refute html =~ "Attendee removed and notified."
      assert invitations() == []
    end
  end

  # A guest's copy of someone else's meeting: the change is theirs to make,
  # but telling the other guests is the organiser's.
  describe "an event someone else organises" do
    setup %{event: event} do
      event = Changeset.change(event, organiser: %{"email" => "someone.else@example.com"})
      {:ok, event: Repo.update!(event)}
    end

    test "adding an attendee saves it without inviting them", %{
      conn: conn,
      event: event,
      integration: integration
    } do
      lv = open_event(conn, event)
      add(lv, "colleague@example.com")

      assert_receive {:write_started, write, _uid, _payload}, @write_timeout
      answer(write, :ok)

      eventually(
        fn ->
          assert render(lv) =~
                   "Attendee added. They were not invited, as you don&#39;t organise this event."
        end,
        timeout: @write_timeout
      )

      assert invitations() == []
      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert "colleague@example.com" in Enum.map(row.attendees, & &1["email"])
    end

    test "removing an attendee saves it without notifying them", %{
      conn: conn,
      event: event,
      integration: integration
    } do
      lv = open_event(conn, event)
      remove(lv, "guest@example.com")

      assert_receive {:write_started, write, _uid, _payload}, @write_timeout
      answer(write, :ok)

      eventually(
        fn ->
          assert render(lv) =~
                   "Attendee removed. They were not notified, as you don&#39;t organise this event."
        end,
        timeout: @write_timeout
      )

      assert invitations() == []
      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.attendees == []
    end
  end

  defp add(lv, email),
    do: lv |> element("#calendar-grid") |> render_hook("add_event_attendee", %{"email" => email})

  defp remove(lv, email) do
    lv
    |> element("#calendar-grid")
    |> render_hook("request_remove_attendee", %{"email" => email})

    lv |> element("#calendar-grid") |> render_hook("confirm_remove_attendee", %{})
  end

  defp invitations do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.map(& &1.args)
    |> Enum.filter(&(&1["action"] == "send_calendar_invitation"))
  end

  # Stands in for a job table that refuses the insert, raised as a
  # constraint Oban's changeset declares so that the insert returns an
  # error rather than raising. Rolled back with the test's sandbox
  # transaction.
  defp refuse_email_jobs! do
    Repo.query!("""
    CREATE FUNCTION test_refuse_email_job() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'email jobs refused' USING ERRCODE = 'check_violation',
        CONSTRAINT = 'priority_range';
    END
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER test_refuse_email_job BEFORE INSERT ON oban_jobs
    FOR EACH ROW WHEN (NEW.worker = 'Tymeslot.Workers.EmailWorker')
    EXECUTE FUNCTION test_refuse_email_job()
    """)
  end
end
