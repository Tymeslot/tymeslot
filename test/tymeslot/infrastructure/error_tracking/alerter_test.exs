defmodule Tymeslot.Infrastructure.ErrorTracking.AlerterTest do
  @moduledoc false

  # async: false: ErrorTracker's `enabled` switch and the admin alert
  # implementation are global application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :integration

  import Mox
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias ExUnit.CaptureLog
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Infrastructure.ErrorTracking.Alerter
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.EmailWorker.AdminAlertScheduler

  # A fixed stacktrace fixes the fingerprint, so every report below of the
  # same exception lands on the same ErrorTracker error.
  @stacktrace [{Tymeslot.Bookings, :create_booking, 2, [file: ~c"lib/bookings.ex", line: 42]}]

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    with_config(:error_tracker, enabled: true)
    :ok
  end

  defp report(message, context \\ %{}) do
    ErrorTracker.report(%RuntimeError{message: message}, @stacktrace, context)
  end

  defp admin_alert_args do
    AdminAlertScheduler.build_args("ops@example.com", "System", :error, "boom", %{},
      dedup_key: "alerter-test"
    )
  end

  defp resolve!(error_id) do
    {:ok, _error} = Error |> Repo.get!(error_id) |> ErrorTracker.resolve()
    :ok
  end

  describe "alerts" do
    setup :capture_admin_alerts

    test "the first occurrence of an error raises one new_error alert" do
      occurrence =
        report("bookings exploded", %{
          "user_id" => 7,
          "correlation_id" => "corr-1",
          "request.method" => "POST",
          "request.path" => "/jane/30min"
        })

      assert_receive {:send_alert, :new_error, payload}

      assert payload.error_id == occurrence.error_id
      assert payload.occurrence_id == occurrence.id
      assert payload.kind == "Elixir.RuntimeError"
      assert payload.reason_message == "bookings exploded"
      assert payload.source_function == "Tymeslot.Bookings.create_booking/2"
      assert payload.source_line == "lib/bookings.ex:42"
      assert payload.user_id == 7
      assert payload.correlation_id == "corr-1"
      assert payload.request_method == "POST"
      assert payload.request_path == "/jane/30min"
      refute_receive {:send_alert, _type, _payload}
    end

    test "a capability in the request path never reaches the alert" do
      report("cancel exploded", %{
        "request.path" => "/jane/meeting/0b7e1f3a-4c1d-4a8e-9f3b-2d6c8e1a5b7c/cancel"
      })

      assert_receive {:send_alert, :new_error, payload}
      assert payload.request_path == "/jane/meeting/:id/cancel"
    end

    test "every metadata value is a scalar the alert email can render" do
      report("bookings exploded", %{
        "live_view.view" => TymeslotWeb.DashboardLive,
        "live_view.event" => "save",
        "live_view.event_params" => %{"nested" => "map"}
      })

      assert_receive {:send_alert, :new_error, payload}
      assert payload.live_view == "TymeslotWeb.DashboardLive"
      assert payload.live_view_event == "save"

      assert Enum.reject(payload, fn {_key, value} ->
               is_binary(value) or is_integer(value) or is_atom(value)
             end) == []
    end

    test "a job's worker, queue and id are carried from the occurrence context" do
      report("job exploded", %{
        "job.worker" => "Tymeslot.Workers.WebhookWorker",
        "job.queue" => "webhooks",
        "job.id" => 314,
        "job.args" => %{"action" => "deliver"}
      })

      assert_receive {:send_alert, :new_error, payload}
      assert payload.job_worker == "Tymeslot.Workers.WebhookWorker"
      assert payload.job_queue == "webhooks"
      assert payload.job_id == 314
      assert payload.job_action == "deliver"
    end

    test "a failed job attempt carries the attempt, the limit and its outcome" do
      expect(EmailServiceMock, :send_admin_alert, fn _to, _category, _severity, _msg, _meta ->
        {:error, :smtp_unreachable}
      end)

      CaptureLog.capture_log(fn ->
        assert {:error, _reason} =
                 perform_job(EmailWorker, admin_alert_args(), attempt: 2, max_attempts: 5)
      end)

      assert_receive {:send_alert, :new_error, payload}
      assert payload.job_worker == "Tymeslot.Workers.EmailWorker"
      assert payload.job_attempt == 2
      assert payload.job_max_attempts == 5
      assert payload.job_state == "failure"
    end

    test "a second occurrence of a known error raises nothing" do
      report("bookings exploded")
      assert_receive {:send_alert, :new_error, _payload}

      report("bookings exploded again")
      refute_receive {:send_alert, _type, _payload}, 200
    end

    test "a resolved error that happens again raises one error_regression alert" do
      first = report("bookings exploded")
      assert_receive {:send_alert, :new_error, _payload}

      resolve!(first.error_id)
      second = report("bookings exploded again")

      assert_receive {:send_alert, :error_regression, payload}
      assert payload.error_id == first.error_id
      assert payload.occurrence_id == second.id
      refute_receive {:send_alert, _type, _payload}, 200
    end

    test "an error unresolved by hand, with no new occurrence, raises nothing" do
      first = report("bookings exploded")
      assert_receive {:send_alert, :new_error, _payload}

      resolve!(first.error_id)
      {:ok, _error} = Error |> Repo.get!(first.error_id) |> ErrorTracker.unresolve()

      refute_receive {:send_alert, _type, _payload}, 200
    end

    test "a muted error that regresses raises nothing" do
      first = report("bookings exploded")
      assert_receive {:send_alert, :new_error, _payload}

      {:ok, _error} = Error |> Repo.get!(first.error_id) |> ErrorTracker.mute()
      resolve!(first.error_id)
      report("bookings exploded again")

      refute_receive {:send_alert, _type, _payload}, 200
    end
  end

  describe "an error raised delivering an admin alert" do
    setup do
      setup_config(:tymeslot,
        admin_alerts_impl: Tymeslot.Infrastructure.AdminAlerts.EmailNotifier,
        admin_alerts_enabled: true,
        admin_alert_email: "ops@example.com"
      )
    end

    # The admin alert email cannot report its own failure: that email would
    # go through the same broken delivery path.
    test "is logged but enqueues no alert email" do
      expect(EmailServiceMock, :send_admin_alert, fn _to, _category, _severity, _msg, _meta ->
        {:error, :smtp_unreachable}
      end)

      log =
        CaptureLog.capture_log(fn ->
          assert {:error, _reason} = perform_job(EmailWorker, admin_alert_args())
        end)

      assert [%Error{kind: "Elixir.Oban.PerformError"}] = Repo.all(Error)
      assert log =~ "Admin alert email suppressed"
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_admin_alert"})
    end

    test "an error in any other job still enqueues an alert email" do
      CaptureLog.capture_log(fn ->
        report("webhook exploded", %{
          "job.worker" => "Tymeslot.Workers.EmailWorker",
          "job.args" => %{"action" => "send_booking_confirmation"}
        })
      end)

      assert_enqueued(worker: EmailWorker, args: %{"action" => "send_admin_alert"})
    end
  end

  defp attached?(event) do
    handler = &Alerter.handle_event/4
    Enum.any?(:telemetry.list_handlers(event), &(&1.function == handler))
  end

  describe "a malformed event" do
    test "is ignored, and the handler stays attached" do
      for {event, metadata} <- [
            {[:error_tracker, :error, :new], %{}},
            {[:error_tracker, :error, :new], %{error: :not_an_error, occurrence: nil}},
            {[:error_tracker, :error, :unresolved], %{error: %Error{id: 1}, occurrence: :junk}}
          ] do
        :telemetry.execute(event, %{system_time: 0}, metadata)
      end

      assert attached?([:error_tracker, :error, :new])
      assert attached?([:error_tracker, :error, :unresolved])
    end
  end
end
