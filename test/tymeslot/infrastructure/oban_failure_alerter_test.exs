defmodule Tymeslot.Infrastructure.ObanFailureAlerterTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @moduletag :infrastructure

  import Tymeslot.AdminAlertsCaptureHelpers

  alias Tymeslot.Infrastructure.ObanFailureAlerter

  setup :capture_admin_alerts

  defp exception_meta(state) do
    %{
      state: state,
      kind: :error,
      reason: %RuntimeError{message: "boom"},
      stacktrace: [],
      job: %Oban.Job{
        id: 99,
        worker: "MyApp.SomeWorker",
        queue: "calendar_events",
        attempt: 5,
        max_attempts: 5,
        args: %{}
      }
    }
  end

  describe "handle_event/4" do
    test "raises an admin alert for a terminal (discarded) failure" do
      ObanFailureAlerter.handle_event(
        [:oban, :job, :exception],
        %{duration: 1000},
        exception_meta(:discard),
        []
      )

      assert_receive {:send_alert, :oban_job_failure, payload}
      assert payload.worker == "MyApp.SomeWorker"
      assert payload.queue == "calendar_events"
      assert payload.job_id == 99
      assert payload.reason_message =~ "boom"
    end

    test "does not alert for a retryable failure" do
      ObanFailureAlerter.handle_event(
        [:oban, :job, :exception],
        %{duration: 1000},
        exception_meta(:failure),
        []
      )

      refute_receive {:send_alert, :oban_job_failure, _payload}
    end
  end

  describe "attach/0 integration" do
    setup do
      # The handler may already be attached from application startup — detach
      # first so attach/0 can reinstall it cleanly against our test impl.
      :telemetry.detach("tymeslot-oban-failure-alerter")
      :ok = ObanFailureAlerter.attach()
      on_exit(fn -> :telemetry.detach("tymeslot-oban-failure-alerter") end)
      :ok
    end

    test "attaches handle_event/4 once for the oban job exception event" do
      handler =
        [:oban, :job, :exception]
        |> :telemetry.list_handlers()
        |> Enum.find(&(&1.id == "tymeslot-oban-failure-alerter"))

      assert handler.event_name == [:oban, :job, :exception]
      assert handler.function == (&ObanFailureAlerter.handle_event/4)

      # Attaching again must not install a duplicate handler that would double-alert.
      assert {:error, :already_exists} = ObanFailureAlerter.attach()
    end

    test "emitting a discard exception event raises an oban_job_failure alert" do
      :telemetry.execute(
        [:oban, :job, :exception],
        %{duration: 2_000},
        exception_meta(:discard)
      )

      assert_receive {:send_alert, :oban_job_failure, payload}
      assert payload.worker == "MyApp.SomeWorker"
      assert payload.reason_message =~ "boom"
    end

    test "emitting a retryable failure event does not alert" do
      :telemetry.execute(
        [:oban, :job, :exception],
        %{duration: 2_000},
        exception_meta(:failure)
      )

      refute_receive {:send_alert, :oban_job_failure, _payload}
    end
  end
end
