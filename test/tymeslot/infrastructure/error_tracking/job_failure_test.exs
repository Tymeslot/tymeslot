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
  alias Oban.TimeoutError
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

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
end
