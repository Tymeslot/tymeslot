defmodule Tymeslot.Infrastructure.ObanFailureAlerterTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.ObanFailureAlerter

  defmodule TestAdminAlerts do
    @spec send_alert(atom(), map()) :: :ok
    def send_alert(event_type, payload) do
      pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)
      send(pid, {:send_alert, event_type, payload})
      :ok
    end
  end

  setup do
    original_impl = Application.get_env(:tymeslot, :admin_alerts_impl)
    original_pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)

    Application.put_env(:tymeslot, :admin_alerts_impl, TestAdminAlerts)
    Application.put_env(:tymeslot, :admin_alerts_test_pid, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :admin_alerts_impl, original_impl)

      if original_pid do
        Application.put_env(:tymeslot, :admin_alerts_test_pid, original_pid)
      else
        Application.delete_env(:tymeslot, :admin_alerts_test_pid)
      end
    end)

    :ok
  end

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
end
