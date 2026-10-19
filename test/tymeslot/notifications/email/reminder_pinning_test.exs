defmodule Tymeslot.Notifications.Email.ReminderPinningTest do
  @moduledoc """
  A reminder job carries the meeting start it was pinned to. One left over
  from before a move (executing as the move lands, so the move could not
  delete it) discards itself before reading or marking anything: it sends no
  second reminder, and it does not mark the new one as sent.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  @moduletag :notifications
  @moduletag :emails

  alias Ecto.Changeset
  alias Oban.Job
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
    profile = insert(:profile)

    meeting =
      insert(:meeting,
        organizer_user: profile.user,
        organizer_user_id: profile.user_id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 1, :hour)
      )

    %{meeting: meeting}
  end

  test "a reminder pinned to the old time discards itself, and the new one still goes out",
       %{meeting: meeting} do
    :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 1, "hours")
    [old] = all_enqueued(worker: EmailWorker)

    # Executing as the move lands, so the move cannot delete it.
    {1, _rows} =
      Repo.update_all(from(j in Job, where: j.id == ^old.id),
        set: [state: "executing"]
      )

    moved = move(meeting, 1)
    :ok = EmailScheduler.schedule_reminder_emails(moved.id, 1, "hours")
    [new] = Enum.reject(all_enqueued(worker: EmailWorker), &(&1.id == old.id))

    expect(Tymeslot.EmailServiceMock, :send_appointment_reminder_to_organizer, 1, fn _email,
                                                                                     _details ->
      {:ok, :sent}
    end)

    expect(Tymeslot.EmailServiceMock, :send_appointment_reminder_to_attendee, 1, fn _email,
                                                                                    _details ->
      {:ok, :sent}
    end)

    # The old job runs first, as it would when it was already executing.
    assert {:discard, "Reminder was for a time the meeting has moved from"} = run(old)
    assert Repo.get!(MeetingSchema, meeting.id).reminders_sent in [nil, []]

    assert :ok = run(new)
  end

  test "a job queued before the pin was carried goes ahead as before", %{meeting: meeting} do
    expect(Tymeslot.EmailServiceMock, :send_appointment_reminder_to_organizer, 1, fn _email,
                                                                                     _details ->
      {:ok, :sent}
    end)

    expect(Tymeslot.EmailServiceMock, :send_appointment_reminder_to_attendee, 1, fn _email,
                                                                                    _details ->
      {:ok, :sent}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_reminder_emails",
               "meeting_id" => meeting.id,
               "reminder_value" => 1,
               "reminder_unit" => "hours"
             })
  end

  # The sent-mark is what the reader checks on a retry, so it is written in
  # the same normalised form the reader looks for.
  test "a reminder whose args carry the value as text is marked sent as a number",
       %{meeting: meeting} do
    stub(Tymeslot.EmailServiceMock, :send_appointment_reminder_to_organizer, fn _email,
                                                                                _details ->
      {:ok, :sent}
    end)

    stub(Tymeslot.EmailServiceMock, :send_appointment_reminder_to_attendee, fn _email, _details ->
      {:ok, :sent}
    end)

    args = %{
      "action" => "send_reminder_emails",
      "meeting_id" => meeting.id,
      "reminder_value" => "1",
      "reminder_unit" => "hour"
    }

    assert :ok = perform_job(EmailWorker, args)

    assert [%{"value" => 1, "unit" => "hours", "organizer_sent" => true, "attendee_sent" => true}] =
             Repo.get!(MeetingSchema, meeting.id).reminders_sent
  end

  defp move(meeting, days) do
    meeting
    |> Changeset.change(
      start_time: DateTime.add(meeting.start_time, days, :day),
      end_time: DateTime.add(meeting.end_time, days, :day)
    )
    |> Repo.update!()
  end

  defp run(job), do: EmailWorker.perform(%{job | attempt: 1})
end
