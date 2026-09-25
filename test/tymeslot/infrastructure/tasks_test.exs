defmodule Tymeslot.Infrastructure.TasksTest do
  @moduledoc false

  # async: false: the crash tests switch ErrorTracker on and install the
  # CrashReporter's `:logger` handler, both global.
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import Tymeslot.ConfigTestHelpers

  alias ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.CrashReporter
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Tasks

  @telemetry_handler "tasks-test-occurrences"

  @doc false
  @spec forward_occurrence([atom()], map(), map(), pid()) :: :ok
  def forward_occurrence(_event, _measurements, %{occurrence: occurrence}, test_pid) do
    send(test_pid, {:occurrence_recorded, occurrence})
    :ok
  end

  # What a task sees: the three keys in Logger metadata, and the same keys and
  # the caller's other ErrorTracker context in its own.
  defp observed_context do
    tracker = ErrorTracking.current_context()

    %{
      logger: Keyword.take(Logger.metadata(), [:correlation_id, :user_id, :request_id]),
      tracker: Map.take(tracker, ["correlation_id", "user_id", "request_id", "request.path"])
    }
  end

  @expected %{
    logger: [correlation_id: "abc12345", user_id: 7, request_id: "req12345"],
    tracker: %{
      "correlation_id" => "abc12345",
      "user_id" => 7,
      "request_id" => "req12345",
      "request.path" => "/dashboard"
    }
  }

  setup do
    ErrorTracking.put_context(correlation_id: "abc12345", user_id: 7, request_id: "req12345")
    ErrorTracker.set_context(%{"request.path" => "/dashboard"})
    :ok
  end

  defp sorted(%{logger: logger} = context), do: %{context | logger: Enum.sort(logger)}

  describe "the task runs with its caller's context" do
    test "async/1" do
      assert sorted(Task.await(Tasks.async(&observed_context/0))) == sorted(@expected)
    end

    test "async/2 under a supervisor" do
      task = Tasks.async(Tymeslot.TaskSupervisor, &observed_context/0)

      assert sorted(Task.await(task)) == sorted(@expected)
    end

    test "async_nolink/2" do
      task = Tasks.async_nolink(Tymeslot.TaskSupervisor, &observed_context/0)

      assert sorted(Task.await(task)) == sorted(@expected)
    end

    test "start_child/2" do
      test_pid = self()

      {:ok, _pid} =
        Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
          send(test_pid, {:context, observed_context()})
        end)

      assert_receive {:context, context}
      assert sorted(context) == sorted(@expected)
    end

    test "async_stream/3, in every task" do
      contexts =
        [1, 2] |> Tasks.async_stream(fn _n -> sorted(observed_context()) end) |> Enum.to_list()

      assert contexts == [ok: sorted(@expected), ok: sorted(@expected)]
    end

    test "async_stream_nolink/4, in every task" do
      contexts =
        Tymeslot.TaskSupervisor
        |> Tasks.async_stream_nolink([1, 2], fn _n -> sorted(observed_context()) end)
        |> Enum.to_list()

      assert contexts == [ok: sorted(@expected), ok: sorted(@expected)]
    end
  end

  describe "a crash inside a task" do
    setup do
      with_config(:error_tracker, enabled: true)

      :ok =
        :telemetry.attach(
          @telemetry_handler,
          [:error_tracker, :occurrence, :new],
          &__MODULE__.forward_occurrence/4,
          self()
        )

      :ok = CrashReporter.attach()

      on_exit(fn ->
        :telemetry.detach(@telemetry_handler)
        CrashReporter.detach()
      end)

      :ok
    end

    test "is recorded with the caller's correlation id and user" do
      CaptureLog.capture_log(fn ->
        {:ok, _pid} = Tasks.start_child(Tymeslot.TaskSupervisor, fn -> raise "task boom" end)

        assert_receive {:occurrence_recorded, occurrence}, 2_000

        assert occurrence.reason == "task boom"
        assert occurrence.context["correlation_id"] == "abc12345"
        assert occurrence.context["user_id"] == 7
      end)
    end
  end
end
