defmodule Tymeslot.Meetings.AttendeeNotifications.MembershipWorkerTest do
  @moduledoc """
  The job that holds a change of who attends until an edit saved to sync
  later has reached the calendar: what it does with an event that is gone,
  a change that never syncs, and an email that cannot be scheduled. The
  journey itself is `TymeslotWeb.Dashboard.CalendarGrid.QueuedEditNotifyLiveViewTest`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :notifications

  alias Ecto.Changeset
  alias Tymeslot.Meetings.AttendeeNotifications.MembershipWorker
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "caldav")

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "caldav",
        attendees: [%{"email" => "new@example.com"}]
      )

    args = %{
      "calendar_integration_id" => integration.id,
      "uid" => event.uid,
      "attendees_before" => [],
      "owner_user_id" => user.id
    }

    {:ok, event: event, args: args}
  end

  test "invites the guests the synced change added", %{args: args} do
    assert :ok = perform_job(MembershipWorker, args)
    assert [%{"attendee_email" => "new@example.com"}] = invitations()
  end

  test "sends nothing for an event that is gone", %{event: event, args: args} do
    Repo.delete!(event)

    assert :ok = perform_job(MembershipWorker, args)
    assert invitations() == []
  end

  test "keeps waiting while the change has not synced, and gives up after a week", %{
    event: event,
    args: args
  } do
    event |> Changeset.change(sync_state: "locally_modified") |> Repo.update!()

    assert {:snooze, _seconds} = perform_job(MembershipWorker, args)

    week_ago = DateTime.add(DateTime.utc_now(), -7, :day)
    assert :ok = perform_job(MembershipWorker, args, inserted_at: week_ago)
    assert invitations() == []
  end

  test "fails for a retry, scheduling nothing, when an email cannot be scheduled", %{args: args} do
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

    assert {:error, _reason} = perform_job(MembershipWorker, args)
    assert invitations() == []
  end

  defp invitations do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.map(& &1.args)
    |> Enum.filter(&(&1["action"] == "send_calendar_invitation"))
  end
end
