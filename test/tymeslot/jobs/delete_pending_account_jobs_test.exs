defmodule Tymeslot.Jobs.DeletePendingAccountJobsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :queries

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Oban.Job
  alias Tymeslot.Jobs
  alias Tymeslot.Meetings
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  defp reminder(meeting_id) do
    %{
      "action" => "send_reminder_emails",
      "meeting_id" => meeting_id,
      "reminder_value" => 1,
      "reminder_unit" => "hours"
    }
    |> EmailWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day))
    |> Oban.insert!()
  end

  defp notice(user_id) do
    %{"action" => "send_signup_attempt_notice", "user_id" => user_id}
    |> EmailWorker.new()
    |> Oban.insert!()
  end

  test "deletes the pending jobs naming the user or one of its meetings, and nothing else" do
    user = insert(:user)
    other = insert(:user)
    meeting = insert(:meeting, organizer_user: user, organizer_email: user.email)
    other_meeting = insert(:meeting, organizer_user: other, organizer_email: other.email)

    reminder(meeting.id)
    notice(user.id)
    kept_reminder = reminder(other_meeting.id)
    kept_notice = notice(other.id)

    assert Meetings.list_meeting_ids_for_organizer(user.id) == [meeting.id]
    assert {2, nil} = Jobs.delete_pending_account_jobs(user.id, [meeting.id])

    enqueued_ids = Enum.sort(Enum.map(all_enqueued(worker: EmailWorker), & &1.id))
    assert enqueued_ids == Enum.sort([kept_reminder.id, kept_notice.id])
  end

  test "leaves an executing job alone" do
    user = insert(:user)
    job = notice(user.id)
    job |> Changeset.change(state: "executing") |> Repo.update!()

    assert {0, nil} = Jobs.delete_pending_account_jobs(user.id, [])
    assert Repo.get(Job, job.id)
  end

  test "matches a user id stored as a string" do
    user = insert(:user)

    string_job =
      %{"action" => "send_signup_attempt_notice", "user_id" => to_string(user.id)}
      |> EmailWorker.new()
      |> Oban.insert!()

    assert {1, nil} = Jobs.delete_pending_account_jobs(user.id, [])
    refute Repo.get(Job, string_job.id)
  end

  test "keeps another user's job whose id merely starts with the same digits" do
    user = insert(:user)
    other = notice(user.id * 10)

    assert {0, nil} = Jobs.delete_pending_account_jobs(user.id, [])
    assert Repo.get(Job, other.id)
  end
end
