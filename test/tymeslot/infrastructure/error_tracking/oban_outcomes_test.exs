defmodule Tymeslot.Infrastructure.ErrorTracking.ObanOutcomesTest do
  # async: false: ErrorTracker's `enabled` switch, the admin alert
  # implementation, the expected-outcomes list and the telemetry handler are
  # all global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :integration

  import Ecto.Query
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.ErrorTracking.JobDiscarded
  alias Tymeslot.Infrastructure.ErrorTracking.ObanOutcomes
  alias Tymeslot.Repo

  defmodule OutcomeWorker do
    @moduledoc false
    use Oban.Worker, queue: :default

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"outcome" => "discard", "reason" => reason}}),
      do: {:discard, reason}

    def perform(%Oban.Job{args: %{"outcome" => "discard_atom", "reason" => reason}}),
      do: {:discard, String.to_existing_atom(reason)}

    def perform(%Oban.Job{args: %{"outcome" => "cancel", "reason" => reason}}),
      do: {:cancel, reason}

    def perform(%Oban.Job{args: %{"outcome" => "ok"}}), do: :ok
  end

  setup do
    with_config(:error_tracker, enabled: true)
    ObanOutcomes.attach()
    on_exit(&ObanOutcomes.detach/0)
    :ok
  end

  defp handlers do
    [:oban, :job, :stop]
    |> :telemetry.list_handlers()
    |> Enum.filter(&(&1.id == "tymeslot-error-tracking-oban-outcomes"))
  end

  defp errors, do: Repo.all(from(e in Error, preload: :occurrences))

  defp run(outcome, reason),
    do: perform_job(OutcomeWorker, %{"outcome" => outcome, "reason" => reason})

  defp stop_event(worker, result) do
    ObanOutcomes.handle_event(
      [:oban, :job, :stop],
      %{},
      %{state: :discard, job: %Oban.Job{worker: worker}, result: result},
      nil
    )
  end

  describe "the expected outcomes shipped in config" do
    test "keep an email worker's cancelled meeting out, and record its timed-out send" do
      stop_event("Tymeslot.Workers.EmailWorker", {:discard, "Meeting cancelled"})
      assert errors() == []

      stop_event("Tymeslot.Workers.EmailWorker", {:discard, "Email sending timed out"})
      assert [%Error{reason: reason}] = errors()
      assert reason =~ "Email sending timed out"
    end

    test "keep an expired refresh grant out, and record a rejected OAuth client" do
      worker = "Tymeslot.Integrations.Calendar.TokenRefreshJob"

      stop_event(worker, {:discard, "Credentials require reauthentication: invalid_grant"})
      assert errors() == []

      stop_event(worker, {:discard, "Credentials require reauthentication: invalid_client"})
      assert [%Error{}] = errors()
    end
  end

  describe "a job the worker discards or cancels" do
    setup do
      setup_config(:tymeslot, :expected_job_outcomes, [
        {:any_worker, ["Meeting not found"]},
        {OutcomeWorker, ["Expected for this worker", {:prefix, "HTTP 4"}]}
      ])
    end

    test "an unlisted discard is recorded with its worker and reason" do
      assert {:discard, :x} = run("discard_atom", "x")

      kind = Atom.to_string(JobDiscarded)
      assert [%Error{kind: ^kind} = error] = errors()
      assert error.reason =~ inspect(OutcomeWorker)
      assert error.reason =~ "discarded the job: :x"
      assert error.source_function =~ "#{inspect(OutcomeWorker)}.perform/1"

      assert [%{context: context}] = error.occurrences
      assert context["job.worker"] == inspect(OutcomeWorker)
      assert context["job_outcome"] == "discard"
    end

    test "an unlisted cancel is recorded" do
      assert {:cancel, "Unplanned"} = run("cancel", "Unplanned")

      assert [%Error{reason: reason}] = errors()
      assert reason =~ "cancelled the job: Unplanned"
    end

    test "two reasons from one worker are two errors, one reason twice is one" do
      run("discard", "First failure")
      run("discard", "First failure")
      run("discard", "Second failure")

      assert errors() |> Enum.map(&length(&1.occurrences)) |> Enum.sort() == [1, 2]
    end

    test "the detail after a colon does not split the error" do
      run("discard", "Invalid datetime: 2026-13-01")
      run("discard", "Invalid datetime: 2026-14-01")

      assert [%Error{occurrences: [_first, _second]}] = errors()
    end

    test "a reason allowlisted for the worker is not recorded" do
      assert {:discard, "Expected for this worker"} = run("discard", "Expected for this worker")
      assert errors() == []
    end

    test "a reason allowlisted for every worker is not recorded" do
      run("discard", "Meeting not found")
      assert errors() == []
    end

    test "a reason matching an allowlisted prefix is not recorded" do
      run("discard", "HTTP 410")
      assert errors() == []

      run("discard", "HTTP 503")
      assert [%Error{}] = errors()
    end

    test "a job that succeeds is not recorded" do
      assert :ok = perform_job(OutcomeWorker, %{"outcome" => "ok"})
      assert errors() == []
    end

    test "a job that raises is left to ErrorTracker's own integration" do
      :ok =
        ObanOutcomes.handle_event(
          [:oban, :job, :exception],
          %{},
          %{state: :failure, job: %Oban.Job{worker: inspect(OutcomeWorker)}},
          nil
        )

      assert errors() == []
    end

    # Telemetry detaches a handler that raises, which would stop recording
    # every later discard until the next restart.
    test "a failure inside the handler is logged, never raised" do
      setup_config(:tymeslot, :expected_job_outcomes, :not_a_list)

      log =
        CaptureLog.capture_log(fn ->
          :telemetry.execute([:oban, :job, :stop], %{}, %{
            state: :discard,
            job: %Oban.Job{worker: inspect(OutcomeWorker)},
            result: {:discard, "x"}
          })
        end)

      assert log =~ "Failed to record a discarded or cancelled Oban job"
      assert handlers() != []
    end
  end

  describe "jobs the Lifeline plugin discards" do
    setup :capture_admin_alerts

    # Dispatched through telemetry, as `Oban.Lifeline` reports a sweep.
    defp lifeline_stop(discarded, rescued) do
      :telemetry.execute([:oban, :plugin, :stop], %{duration: 1}, %{
        plugin: Oban.Lifeline,
        discarded_jobs: discarded,
        rescued_jobs: rescued
      })
    end

    test "raise one force-discarded alert naming each worker and queue" do
      jobs = [
        %Oban.Job{id: 1, worker: "Tymeslot.Workers.EmailWorker", queue: "emails"},
        %Oban.Job{id: 2, worker: "Tymeslot.Workers.EmailWorker", queue: "emails"},
        %Oban.Job{id: 3, worker: "Tymeslot.Workers.VideoRoomWorker", queue: "video"}
      ]

      lifeline_stop(jobs, [])

      assert_receive {:send_alert, :oban_jobs_force_discarded, payload}
      assert payload.count == 3
      assert payload.discarded_by == "Oban.Lifeline"
      assert payload.jobs =~ "Tymeslot.Workers.EmailWorker (emails): 2"
      assert payload.jobs =~ "Tymeslot.Workers.VideoRoomWorker (video): 1"
      assert payload.job_ids == "1, 2, 3"
      refute_receive {:send_alert, _type, _payload}
    end

    test "raise nothing when the plugin discarded nothing" do
      lifeline_stop([], [%Oban.Job{id: 1, worker: "W", queue: "q"}])

      refute_receive {:send_alert, _type, _payload}
    end
  end
end
