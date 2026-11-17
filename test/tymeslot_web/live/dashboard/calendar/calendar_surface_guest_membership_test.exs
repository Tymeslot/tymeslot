defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceGuestMembershipTest do
  @moduledoc """
  Telling a guest they were invited to an event from the side panel, or
  taken off it: the invitation or cancellation is sent only once the
  calendar has accepted the write.

  Sent before, a write the calendar then refused left the guest with an
  invitation to an event they were not on, or a cancellation of one they
  were still on.

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

  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers
  import TymeslotWeb.CalendarSurfaceWriteHelpers

  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  @write_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    hold_writes()

    review =
      event(context.integration, "work", "Design review", ~U[2026-10-14 14:00:00Z], 60,
        attendees: [%{"email" => "guest@example.com", "display_name" => "Guest"}]
      )

    Map.put(context, :review, review)
  end

  describe "inviting a guest" do
    test "emails them once the calendar has accepted the write", %{conn: conn, review: review} do
      lv = open_event(conn, review)
      invite(lv, "new@example.com")

      assert_receive {:write_started, write, _uid, %{attendees: attendees}}, @write_timeout
      assert "new@example.com" in emails(attendees)

      # Nothing is sent, nor claimed, while the calendar has not answered.
      settled(lv)
      assert invitations() == []
      refute has_element?(lv, "#calendar-toast", "Invited new@example.com.")

      answer(write, :ok)
      settled(lv)

      assert [%{"attendee_email" => "new@example.com", "method" => "request"}] = invitations()
      assert has_element?(lv, "#calendar-toast", "Invited new@example.com.")
    end

    test "emails nobody when the calendar refuses the write", %{conn: conn, review: review} do
      lv = open_event(conn, review)
      invite(lv, "new@example.com")

      assert_receive {:write_started, write, _uid, _payload}, @write_timeout
      answer(write, {:error, :unauthorized})

      assert settled(lv) =~ "Failed to update event"
      refute has_element?(lv, "#calendar-panel-guests li", "new@example.com")
      refute has_element?(lv, "#calendar-toast", "Invited new@example.com.")
      assert invitations() == []
    end

    test "says so when the invitation could not be scheduled", %{conn: conn, review: review} do
      lv = open_event(conn, review)
      invite(lv, "new@example.com")

      assert_receive {:write_started, write, _uid, _payload}, @write_timeout
      refuse_email_jobs!()
      answer(write, :ok)

      eventually(
        fn -> assert render(lv) =~ "Attendee added, but their invitation could not be sent." end,
        timeout: @write_timeout
      )

      refute has_element?(lv, "#calendar-toast", "Invited new@example.com.")
    end

    # Each write carries its own notification, so the second invite cannot
    # overwrite the first's answer.
    test "two quick invites email both guests", %{conn: conn, review: review} do
      lv = open_event(conn, review)
      invite(lv, "first@example.com")
      invite(lv, "second@example.com")

      assert_receive {:write_started, first, _uid, _payload}, @write_timeout
      answer(first, :ok)
      assert_receive {:write_started, second, _uid, _payload}, @write_timeout
      answer(second, :ok)
      settled(lv)

      assert invitations() |> Enum.map(& &1["attendee_email"]) |> Enum.sort() ==
               ["first@example.com", "second@example.com"]
    end

    # The second write sends the list the panel showed, first guest included,
    # so the calendar puts them on after all; they are emailed then.
    test "a guest whose own write failed is emailed once a later write puts them on", %{
      conn: conn,
      review: review
    } do
      lv = open_event(conn, review)
      invite(lv, "first@example.com")
      invite(lv, "second@example.com")

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

    test "still emails them when the LiveView is gone before the calendar answers", %{
      conn: conn,
      review: review
    } do
      lv = open_event(conn, review)
      invite(lv, "new@example.com")

      assert_receive {:write_started, write, _uid, _payload}, @write_timeout
      kill(lv)
      answer(write, :ok)

      eventually(fn -> assert [%{"attendee_email" => "new@example.com"}] = invitations() end,
        timeout: @write_timeout
      )
    end
  end

  describe "removing a guest" do
    test "tells them once the calendar has accepted the write", %{conn: conn, review: review} do
      lv = open_event(conn, review)
      remove(lv, "guest@example.com")

      assert_receive {:write_started, write, _uid, %{attendees: []}}, @write_timeout
      settled(lv)
      assert invitations() == []
      refute has_element?(lv, "#calendar-toast", "Removed guest@example.com.")

      answer(write, :ok)
      settled(lv)

      assert [%{"attendee_email" => "guest@example.com", "method" => "cancel"}] = invitations()
      assert has_element?(lv, "#calendar-toast", "Removed guest@example.com.")
    end

    test "tells nobody when the calendar refuses the write", %{conn: conn, review: review} do
      lv = open_event(conn, review)
      remove(lv, "guest@example.com")

      assert_receive {:write_started, write, _uid, _payload}, @write_timeout
      answer(write, {:error, :unauthorized})

      assert settled(lv) =~ "Failed to update event"
      refute has_element?(lv, "#calendar-toast", "Removed guest@example.com.")
      assert invitations() == []
    end
  end

  defp invite(lv, email),
    do: lv |> form("#calendar-panel-guest-form") |> render_submit(%{"email" => email})

  defp remove(lv, email) do
    lv
    |> element(~s|#calendar-panel-guests button[phx-value-email="#{email}"]|)
    |> render_click()

    lv |> element("#calendar-remove-guest-confirm") |> render_click()
  end

  defp emails(attendees), do: Enum.map(attendees, &(Map.get(&1, :email) || &1["email"]))

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
