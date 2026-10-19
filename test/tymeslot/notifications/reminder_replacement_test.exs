defmodule Tymeslot.Notifications.ReminderReplacementTest do
  @moduledoc """
  Re-pinning a moved meeting's reminders: the old jobs go and the new ones
  arrive together, and a reminder still executing for the old time does not
  stop the one for the new time.
  """

  # async: false: one test refuses reminder inserts by patching Oban.insert/1
  # with :meck, which replaces the module for every process.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Tymeslot.Factory

  @moduletag :notifications

  alias Ecto.Changeset
  alias Oban.Job
  alias Tymeslot.Notifications.Orchestrator

  setup do
    start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

    meeting =
      insert(:meeting,
        start_time: start_time,
        end_time: DateTime.add(start_time, 1, :hour),
        reminders: [%{"value" => 1, "unit" => "hours"}]
      )

    %{meeting: meeting}
  end

  test "a failed insert leaves the old reminder in place rather than none", %{meeting: meeting} do
    assert :ok = Orchestrator.schedule_reminder_notifications(meeting)
    assert [old] = reminder_jobs(meeting)

    :meck.new(Oban, [:passthrough])

    :meck.expect(Oban, :insert, fn changeset ->
      if Changeset.get_field(changeset, :args)["action"] == "send_reminder_emails",
        do: {:error, :queue_not_available},
        else: :meck.passthrough([changeset])
    end)

    try do
      capture_log(fn ->
        assert {:error, _reason} =
                 Orchestrator.schedule_reminder_notifications(moved(meeting), replace: true)
      end)
    after
      :meck.unload(Oban)
    end

    assert [%{id: id}] = reminder_jobs(meeting)
    assert id == old.id
  end

  test "a reminder executing for the old time does not block the new one", %{meeting: meeting} do
    assert :ok = Orchestrator.schedule_reminder_notifications(meeting)
    assert [old] = reminder_jobs(meeting)
    {1, _rows} = Repo.update_all(from_job(old.id), set: [state: "executing"])

    moved = moved(meeting)
    assert :ok = Orchestrator.schedule_reminder_notifications(moved, replace: true)

    assert [new] = Enum.reject(reminder_jobs(meeting), &(&1.id == old.id))
    assert new.state == "scheduled"
    assert DateTime.compare(new.scheduled_at, DateTime.add(moved.start_time, -1, :hour)) == :eq
  end

  test "a new meeting's reminders are pinned without clearing anything", %{meeting: meeting} do
    assert :ok = Orchestrator.schedule_reminder_notifications(meeting)
    assert [old] = reminder_jobs(meeting)

    # Without `replace: true` the pending job stays; scheduling the same
    # reminder again is a duplicate of it, not a replacement.
    assert :ok = Orchestrator.schedule_reminder_notifications(meeting)
    assert [%{id: id}] = reminder_jobs(meeting)
    assert id == old.id
  end

  defp moved(meeting) do
    start_time = DateTime.add(meeting.start_time, 1, :day)
    %{meeting | start_time: start_time, end_time: DateTime.add(start_time, 1, :hour)}
  end

  defp reminder_jobs(meeting) do
    Repo.all(
      from(j in Job,
        where: j.worker == "Tymeslot.Workers.EmailWorker",
        where: fragment("?->>'action' = 'send_reminder_emails'", j.args),
        where: fragment("?->>'meeting_id' = ?", j.args, ^meeting.id),
        order_by: j.id
      )
    )
  end

  defp from_job(id), do: from(j in Job, where: j.id == ^id)
end
