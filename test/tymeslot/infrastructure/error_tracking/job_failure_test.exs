defmodule Tymeslot.Infrastructure.ErrorTracking.JobFailureTest do
  # async: false: ErrorTracker's `enabled` switch and the admin alert
  # implementation are global application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :integration

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias ExUnit.CaptureLog
  alias Oban.PerformError
  alias Oban.TimeoutError
  alias Tymeslot.Infrastructure.ErrorTracking.JobDiscardedError
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.EmailWorker.AdminAlertScheduler

  defmodule FailingWorker do
    @moduledoc false
    use Oban.Worker, queue: :default, max_attempts: 3

    @behaviour ExpectedJobOutcome

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"raise" => message}}), do: raise(message)
    def perform(%Oban.Job{args: %{"reason" => reason}}), do: {:error, reason}

    @impl ExpectedJobOutcome
    def expected_outcome?("Mailbox gone"), do: true
    def expected_outcome?(_reason), do: false
  end

  setup do
    with_config(:error_tracker, enabled: true)
    :ok
  end

  defp job(attrs) do
    struct!(
      %Oban.Job{
        id: 4242,
        worker: "Tymeslot.Workers.WebhookWorker",
        queue: "webhooks",
        args: %{"action" => "deliver"},
        priority: 0,
        attempt: 3,
        max_attempts: 3
      },
      attrs
    )
  end

  # Oban reports a job that times out, or whose process is killed by a
  # linked crash, from a fresh task under its foreman: a process that never
  # ran the job, and so carries none of its ErrorTracker context.
  defp fail_outside_job_process(job, state) do
    metadata = %{
      job: job,
      kind: :error,
      reason: TimeoutError.exception({job.worker, 1_000}),
      error: TimeoutError.exception({job.worker, 1_000}),
      result: nil,
      stacktrace: [],
      state: state
    }

    fn -> :telemetry.execute([:oban, :job, :exception], %{duration: 0}, metadata) end
    |> Task.async()
    |> Task.await()
  end

  describe "a job that fails outside its own process" do
    test "is recorded with the job's context" do
      CaptureLog.capture_log(fn -> fail_outside_job_process(job(attempt: 1), :failure) end)

      assert [%Error{occurrences: [%{context: context}]}] =
               Repo.preload(Repo.all(Error), :occurrences)

      assert context["job.id"] == 4242
      assert context["job.worker"] == "Tymeslot.Workers.WebhookWorker"
      assert context["job.queue"] == "webhooks"
      assert context["job.attempt"] == 1
      assert context["job.max_attempts"] == 3
    end

    test "alerts with the job's id and worker" do
      capture_admin_alerts()

      CaptureLog.capture_log(fn -> fail_outside_job_process(job([]), :discard) end)

      assert_receive {:send_alert, :new_error, payload}
      assert payload.job_id == 4242
      assert payload.job_worker == "Tymeslot.Workers.WebhookWorker"
    end

    test "enqueues no alert email when it was delivering an admin alert" do
      setup_config(:tymeslot,
        admin_alerts_impl: Tymeslot.Infrastructure.AdminAlerts.EmailNotifier,
        admin_alerts_enabled: true,
        admin_alert_email: "ops@example.com"
      )

      alert_job =
        job(
          worker: inspect(EmailWorker),
          queue: "emails",
          args: %{"action" => "send_admin_alert"}
        )

      log = CaptureLog.capture_log(fn -> fail_outside_job_process(alert_job, :discard) end)

      assert [%Error{}] = Repo.all(Error)
      assert log =~ "Admin alert email suppressed"
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_admin_alert"})
    end
  end

  defp attempt(args, attempt) do
    CaptureLog.capture_log(fn ->
      try do
        perform_job(FailingWorker, args, attempt: attempt, max_attempts: 3)
      rescue
        RuntimeError -> :raised
      end
    end)
  end

  defp errors, do: Repo.preload(Repo.all(Error), :occurrences)

  describe "a job that fails and can still retry" do
    setup :capture_admin_alerts

    test "is recorded but raises no alert" do
      attempt(%{"reason" => "Provider unavailable"}, 1)

      assert [%Error{kind: "Elixir.Oban.PerformError"}] = errors()
      refute_receive {:send_alert, _type, _payload}
    end
  end

  describe "a job that fails on its last attempt" do
    setup :capture_admin_alerts

    test "alerts, although earlier attempts of the worker were recorded" do
      attempt(%{"reason" => "Provider unavailable"}, 1)
      attempt(%{"reason" => "Provider unavailable"}, 2)
      refute_receive {:send_alert, _type, _payload}

      attempt(%{"reason" => "Provider unavailable"}, 3)

      assert_receive {:send_alert, :new_error, payload}
      assert payload.kind == Atom.to_string(JobDiscardedError)
      assert payload.job_worker == inspect(FailingWorker)
      assert payload.job_outcome == "exhausted"
      assert payload.job_attempt == 3
    end

    test "is recorded once, as the job giving up, not also as the failure" do
      attempt(%{"reason" => "Provider unavailable"}, 3)

      kind = Atom.to_string(JobDiscardedError)
      assert [%Error{kind: ^kind} = error] = errors()
      assert error.reason =~ inspect(FailingWorker)
      assert error.reason =~ "Provider unavailable"
    end

    test "keeps the stacktrace of an exception the worker raised" do
      attempt(%{"raise" => "job exploded"}, 3)

      assert [%Error{reason: reason, occurrences: [occurrence]}] = errors()
      assert reason =~ "job exploded"

      assert Enum.any?(
               occurrence.stacktrace.lines,
               &(&1.module == inspect(FailingWorker) and &1.line > 0)
             )
    end

    test "raises one alert for each reason's first exhaustion" do
      attempt(%{"reason" => "Provider unavailable"}, 3)
      attempt(%{"reason" => "Provider unavailable"}, 3)
      attempt(%{"reason" => "Quota exceeded"}, 3)

      assert_receive {:send_alert, :new_error, first}
      assert_receive {:send_alert, :new_error, second}
      refute_receive {:send_alert, _type, _payload}
      assert first.error_id != second.error_id
    end

    test "is not recorded when the worker declares the reason expected" do
      attempt(%{"reason" => "Mailbox gone"}, 3)

      assert errors() == []
      refute_receive {:send_alert, _type, _payload}
    end
  end

  describe "an admin alert email job that fails on its last attempt" do
    setup do
      setup_config(:tymeslot,
        admin_alerts_impl: Tymeslot.Infrastructure.AdminAlerts.EmailNotifier,
        admin_alerts_enabled: true,
        admin_alert_email: "ops@example.com"
      )
    end

    for action <- AdminAlertScheduler.actions() do
      test "enqueues no alert email for #{action}" do
        alert_job =
          job(
            worker: inspect(EmailWorker),
            queue: "emails",
            args: %{"action" => unquote(action)},
            attempt: 5,
            max_attempts: 5
          )

        metadata = %{
          job: alert_job,
          kind: :error,
          reason: PerformError.exception({alert_job.worker, {:error, :smtp_unreachable}}),
          result: {:error, :smtp_unreachable},
          stacktrace: [],
          state: :discard
        }

        log =
          CaptureLog.capture_log(fn ->
            :telemetry.execute([:oban, :job, :exception], %{duration: 0}, metadata)
          end)

        assert [%Error{}] = Repo.all(Error)
        assert log =~ "Admin alert email suppressed"
        refute_enqueued(worker: EmailWorker, args: %{"action" => unquote(action)})
      end
    end
  end
end
