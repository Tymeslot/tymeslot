defmodule Tymeslot.Jobs.ObanJobQueriesTest do
  @moduledoc """
  Verifies that the hand-rolled "pending job" queries agree with the workers'
  Oban `unique: [states: ...]` guards. In particular a `suspended` job has not
  reached a terminal state and must be treated as pending, so the manual
  duplicate-prevention checks do not allow a double-enqueue.
  """
  use Tymeslot.DataCase, async: true

  import Ecto.Query

  @moduletag :workers
  @moduletag :queries

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Jobs.ObanJobQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker

  @worker "Tymeslot.Workers.SomeMaintenanceWorker"

  describe "count_active_maintenance_jobs/1" do
    test "counts a suspended job as active" do
      insert_job(%{worker: @worker, state: "suspended"})

      assert ObanJobQueries.count_active_maintenance_jobs(@worker) == 1
    end

    # A run waiting to retry has not finished either; counting it as absent
    # let a second run be scheduled behind it.
    test "counts every incomplete job, retryable included" do
      for state <- ~w(available scheduled executing retryable suspended) do
        insert_job(%{worker: @worker, state: state})
      end

      assert ObanJobQueries.count_active_maintenance_jobs(@worker) == 5
    end

    test "ignores terminal jobs" do
      for state <- ~w(completed discarded cancelled) do
        insert_job(%{worker: @worker, state: state})
      end

      assert ObanJobQueries.count_active_maintenance_jobs(@worker) == 0
    end
  end

  describe "user_ids_with_pending_jobs_for_actions/2" do
    test "treats a suspended job as pending" do
      insert_job(%{
        worker: @worker,
        state: "suspended",
        args: %{"action" => "notify", "user_id" => 42}
      })

      assert ObanJobQueries.user_ids_with_pending_jobs_for_actions(@worker, ["notify"]) == [42]
    end

    test "does not return users whose only job is terminal" do
      insert_job(%{
        worker: @worker,
        state: "completed",
        args: %{"action" => "notify", "user_id" => 7}
      })

      assert ObanJobQueries.user_ids_with_pending_jobs_for_actions(@worker, ["notify"]) == []
    end
  end

  describe "delete_meeting_jobs/2" do
    test "deletes a pending job for the meeting" do
      insert_job(%{
        worker: @worker,
        state: "scheduled",
        args: %{"meeting_id" => "meeting-1"}
      })

      assert {1, nil} = ObanJobQueries.delete_meeting_jobs(@worker, "meeting-1")
    end

    test "ignores a job in a terminal state" do
      insert_job(%{
        worker: @worker,
        state: "completed",
        args: %{"meeting_id" => "meeting-1"}
      })

      assert {0, nil} = ObanJobQueries.delete_meeting_jobs(@worker, "meeting-1")
    end
  end

  describe "pending_meeting_job?/2" do
    test "is true for a queued calendar job of the meeting" do
      meeting_id = UUID.generate()
      {:ok, :scheduled} = CalendarJobs.schedule_job(%{id: meeting_id}, "update")

      assert ObanJobQueries.pending_meeting_job?(CalendarEventWorker, meeting_id)
    end

    test "is false once that job has completed" do
      meeting_id = UUID.generate()
      {:ok, :scheduled} = CalendarJobs.schedule_job(%{id: meeting_id}, "update")
      Repo.update_all(Oban.Job, set: [state: "completed"])

      refute ObanJobQueries.pending_meeting_job?(CalendarEventWorker, meeting_id)
    end

    test "is false for another meeting's job" do
      {:ok, :scheduled} = CalendarJobs.schedule_job(%{id: UUID.generate()}, "update")

      refute ObanJobQueries.pending_meeting_job?(CalendarEventWorker, UUID.generate())
    end

    test "is false for another worker's job" do
      meeting_id = UUID.generate()

      Oban.insert!(
        EmailWorker.new(%{
          "meeting_id" => meeting_id,
          "action" => "send_reminder_emails",
          "reminder_value" => 24,
          "reminder_unit" => "hours"
        })
      )

      refute ObanJobQueries.pending_meeting_job?(CalendarEventWorker, meeting_id)
    end
  end

  describe "pending_meeting_job?/2 across states" do
    test "is true in every incomplete state and false in every terminal one" do
      for state <- ~w(available scheduled executing retryable suspended) do
        meeting_id = UUID.generate()
        insert_calendar_job(meeting_id, %{state: state})

        assert ObanJobQueries.pending_meeting_job?(CalendarEventWorker, meeting_id), state
      end

      for state <- ~w(completed discarded cancelled) do
        meeting_id = UUID.generate()
        insert_calendar_job(meeting_id, %{state: state})

        refute ObanJobQueries.pending_meeting_job?(CalendarEventWorker, meeting_id), state
      end
    end
  end

  describe "meeting_job_since?/3" do
    setup do
      %{since: DateTime.utc_now(), meeting_id: UUID.generate()}
    end

    test "is true for a job still pending", %{since: since, meeting_id: meeting_id} do
      insert_calendar_job(meeting_id, %{state: "retryable"})

      assert ObanJobQueries.meeting_job_since?(CalendarEventWorker, meeting_id, since)
    end

    test "is true for a job completed at or after the instant",
         %{since: since, meeting_id: meeting_id} do
      insert_calendar_job(meeting_id, %{
        state: "completed",
        completed_at: DateTime.add(since, 1, :second)
      })

      assert ObanJobQueries.meeting_job_since?(CalendarEventWorker, meeting_id, since)
    end

    test "is false for a job completed before the instant",
         %{since: since, meeting_id: meeting_id} do
      insert_calendar_job(meeting_id, %{
        state: "completed",
        completed_at: DateTime.add(since, -1, :second)
      })

      refute ObanJobQueries.meeting_job_since?(CalendarEventWorker, meeting_id, since)
    end

    # Neither wrote anything to the calendar, so neither can make what was
    # read stale.
    test "is false for a job discarded or cancelled after the instant",
         %{since: since, meeting_id: meeting_id} do
      after_since = DateTime.add(since, 1, :second)
      insert_calendar_job(meeting_id, %{state: "discarded", discarded_at: after_since})
      insert_calendar_job(meeting_id, %{state: "cancelled", cancelled_at: after_since})

      refute ObanJobQueries.meeting_job_since?(CalendarEventWorker, meeting_id, since)
    end

    test "is false for another meeting's job", %{since: since, meeting_id: meeting_id} do
      insert_calendar_job(UUID.generate(), %{
        state: "completed",
        completed_at: DateTime.add(since, 1, :second)
      })

      refute ObanJobQueries.meeting_job_since?(CalendarEventWorker, meeting_id, since)
    end
  end

  describe "update_job_to_discarded/2" do
    test "discards a job still executing and appends the error" do
      job = insert_job(%{state: "executing", errors: [%{"error" => "earlier"}]})

      assert {:ok, :discarded} =
               ObanJobQueries.update_job_to_discarded(job, %{error: "stuck", attempt: 1})

      assert %{state: "discarded", discarded_at: %DateTime{}, errors: errors} = Repo.reload!(job)
      assert [%{"error" => "earlier"}, %{"error" => "stuck", "attempt" => 1}] = errors
    end

    # The maintenance worker read the job as stuck; it finished before the
    # discard landed, and must not be marked as dropped.
    test "leaves a job that finished after it was read" do
      stale = insert_job(%{state: "executing"})
      Repo.update_all(from(j in Oban.Job, where: j.id == ^stale.id), set: [state: "completed"])

      assert {:error, :no_longer_executing} =
               ObanJobQueries.update_job_to_discarded(stale, %{error: "stuck"})

      assert %{state: "completed", errors: []} = Repo.reload!(stale)
    end
  end

  defp insert_calendar_job(meeting_id, attrs) do
    insert_job(
      Map.merge(
        %{
          worker: "Tymeslot.Workers.CalendarEventWorker",
          queue: "calendar_events",
          args: %{"action" => "update", "meeting_id" => meeting_id}
        },
        attrs
      )
    )
  end

  defp insert_job(attrs) do
    default_attrs = %{
      worker: "DefaultWorker",
      queue: "default",
      state: "available",
      args: %{},
      attempt: 0,
      max_attempts: 20,
      inserted_at: DateTime.utc_now(),
      scheduled_at: DateTime.utc_now()
    }

    %Oban.Job{}
    |> Changeset.change(Map.merge(default_attrs, attrs))
    |> Repo.insert!()
  end
end
