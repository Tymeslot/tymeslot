defmodule Tymeslot.Infrastructure.ErrorTracking.ObanOutcomesTest do
  # async: false: ErrorTracker's `enabled` switch, the admin alert
  # implementation and the telemetry handler are all global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :integration

  import Ecto.Query
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias ExUnit.CaptureLog
  alias Oban.Engine
  alias Tymeslot.Infrastructure.ErrorTracking.JobDiscarded
  alias Tymeslot.Infrastructure.ErrorTracking.ObanOutcomes
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
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

  defmodule DeclaringWorker do
    @moduledoc false
    use Oban.Worker, queue: :default

    @behaviour ExpectedJobOutcome

    @expected "Expected for this worker"

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"reason" => reason}}), do: {:discard, reason}

    @impl ExpectedJobOutcome
    def expected_outcome?(@expected), do: true
    def expected_outcome?("HTTP 4" <> _status), do: true
    def expected_outcome?(_reason), do: false
  end

  defmodule RaisingWorker do
    @moduledoc false
    use Oban.Worker, queue: :default

    @behaviour ExpectedJobOutcome

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"reason" => reason}}), do: {:discard, reason}

    @impl ExpectedJobOutcome
    def expected_outcome?(_reason), do: raise("broken check")
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

  describe "the outcomes Core's workers declare expected" do
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

  describe "a worker that declares expected outcomes" do
    defp declared(reason), do: perform_job(DeclaringWorker, %{"reason" => reason})

    test "has a reason it declares expected left out" do
      assert {:discard, "Expected for this worker"} = declared("Expected for this worker")
      assert errors() == []
    end

    test "has a reason matching a declared pattern left out, and others recorded" do
      declared("HTTP 410")
      assert errors() == []

      declared("HTTP 503")
      assert [%Error{}] = errors()
    end

    test "has its outcome recorded when the check raises" do
      log =
        CaptureLog.capture_log(fn ->
          assert {:discard, "Anything"} = perform_job(RaisingWorker, %{"reason" => "Anything"})
        end)

      assert [%Error{}] = errors()
      assert log =~ "Expected outcome check failed"
    end

    test "is not asked about a worker name that resolves to no module" do
      stop_event("Tymeslot.Workers.NoSuchWorkerEverDefined", {:discard, "gone"})
      assert [%Error{}] = errors()
    end
  end

  describe "a worker without the expected outcome callback" do
    test "has a discard recorded with its worker and reason" do
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

    test "has a cancel recorded" do
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

    # A reason that interpolates an id or a time without a colon must not
    # mint a new error group, and with it a new alert, for every value.
    for {label, first, second} <- [
          {"digits", "Meeting 123 not found", "Meeting 4567 not found"},
          {"a UUID", "Room 3f1c2a4e-9b7d-4c1e-8a2f-5d6b7c8e9f01 gone",
           "Room 0b7e1f3a-4c1d-4a8e-9f3b-2d6c8e1a5b7c gone"},
          {"a hex id", "Event a3f9c0d2e1b4 unreadable", "Event 77ffee001122 unreadable"},
          {"an ISO timestamp", "Not due until 2026-09-27T18:00:00Z",
           "Not due until 2026-10-01 09:30:15.123456Z"}
        ] do
      test "keeps reasons differing only in #{label} in one error" do
        run("discard", unquote(first))
        run("discard", unquote(second))

        assert [%Error{occurrences: [_first, _second]}] = errors()
      end
    end

    test "has even a reason another worker expects recorded" do
      run("discard", "Expected for this worker")
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
      log =
        CaptureLog.capture_log(fn ->
          :telemetry.execute([:oban, :job, :stop], %{}, %{
            state: :discard,
            job: %Oban.Job{worker: nil},
            result: {:discard, "x"}
          })
        end)

      assert log =~ "Failed to record a discarded or cancelled Oban job"
      assert handlers() != []
    end
  end

  describe "jobs the Lifeline plugin discards" do
    setup :capture_admin_alerts

    defp insert_abandoned_job(worker, queue, attempt, max_attempts) do
      abandoned_at = DateTime.add(DateTime.utc_now(), -2, :hour)

      Repo.insert!(%Oban.Job{
        state: "executing",
        worker: worker,
        queue: queue,
        args: %{},
        attempt: attempt,
        max_attempts: max_attempts,
        attempted_at: abandoned_at,
        inserted_at: abandoned_at
      })
    end

    # Runs one Lifeline sweep the way `Oban.Lifeline` does: the engine rescues
    # the abandoned rows, returning plain maps of `id`, `queue` and `state`,
    # and the sweep reports the ones it discarded through telemetry.
    defp lifeline_sweep do
      {:ok, rescued} =
        Engine.rescue_jobs(Oban.config(), Oban.Job, rescue_after: :timer.hours(1))

      {rescued, discarded} = Enum.split_with(rescued, &(&1.state == "available"))

      :telemetry.execute([:oban, :plugin, :stop], %{duration: 1}, %{
        plugin: Oban.Lifeline,
        discarded_jobs: discarded,
        rescued_jobs: rescued
      })

      discarded
    end

    test "raise one force-discarded alert naming each worker and queue" do
      ids =
        for {worker, queue} <- [
              {"Tymeslot.Workers.EmailWorker", "emails"},
              {"Tymeslot.Workers.EmailWorker", "emails"},
              {"Tymeslot.Workers.VideoRoomWorker", "video_rooms"}
            ] do
          insert_abandoned_job(worker, queue, 3, 3).id
        end

      # A job with attempts left is rescued, not discarded.
      insert_abandoned_job("Tymeslot.Workers.SlackWorker", "notifications", 1, 3)

      assert [%{id: _id, queue: _queue, state: "discarded"} | _more] = lifeline_sweep()

      assert_receive {:send_alert, :oban_jobs_force_discarded, payload}
      assert payload.count == 3
      assert payload.discarded_by == "Oban.Lifeline"
      assert payload.jobs =~ "Tymeslot.Workers.EmailWorker (emails): 2"
      assert payload.jobs =~ "Tymeslot.Workers.VideoRoomWorker (video_rooms): 1"
      refute payload.jobs =~ "SlackWorker"
      assert payload.job_ids == ids |> Enum.sort() |> Enum.join(", ")
      refute_receive {:send_alert, _type, _payload}
    end

    # The engine's maps carry no worker, which is looked up by id. A row gone
    # by then (pruned, or deleted by hand) still counts under its queue.
    test "count a job whose row is gone under its queue alone" do
      lifeline_stop_event([%{id: -1, queue: "emails", state: "discarded"}])

      assert_receive {:send_alert, :oban_jobs_force_discarded, payload}
      assert payload.count == 1
      assert payload.jobs == "unknown worker (emails): 1"
    end

    test "raise nothing when the plugin discarded nothing" do
      insert_abandoned_job("Tymeslot.Workers.SlackWorker", "notifications", 1, 3)

      assert lifeline_sweep() == []
      refute_receive {:send_alert, _type, _payload}
    end

    defp lifeline_stop_event(discarded) do
      :telemetry.execute([:oban, :plugin, :stop], %{duration: 1}, %{
        plugin: Oban.Lifeline,
        discarded_jobs: discarded,
        rescued_jobs: []
      })
    end
  end
end
