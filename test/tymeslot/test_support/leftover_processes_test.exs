defmodule Tymeslot.Test.LeftoverProcessesTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support
  @moduletag :unit

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Test.LeftoverProcesses

  describe "kill_processes_of/1" do
    test "kills the background tasks started on behalf of a test, and no others" do
      other_test = spawn_test_process()
      leftover = start_task(other_test)
      unrelated = start_task(spawn_test_process())

      assert :ok = LeftoverProcesses.kill_processes_of(other_test)

      refute Process.alive?(leftover)
      assert Process.alive?(unrelated)
    end

    test "kills a task that another of the test's tasks started" do
      other_test = spawn_test_process()
      child = start_task(start_task(other_test))

      LeftoverProcesses.kill_processes_of(other_test)

      refute Process.alive?(child)
    end

    test "kills a task started under the error tracker's supervisor" do
      other_test = spawn_test_process()
      report = start_task(other_test, ErrorTracking.task_supervisor())

      LeftoverProcesses.kill_processes_of(other_test)

      refute Process.alive?(report)
    end
  end

  # A stand-in for a test process, or for a task one started: on request it
  # starts a task under one of the application's task supervisors, which
  # carries it in its `$callers` as a task the code under test starts would.
  defp spawn_test_process do
    pid = spawn(&serve/0)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp start_task(starter, supervisor \\ Tymeslot.TaskSupervisor) do
    send(starter, {:start_task, supervisor, self()})
    assert_receive {:task, pid}
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp serve do
    receive do
      {:start_task, supervisor, reply_to} ->
        {:ok, pid} = Task.Supervisor.start_child(supervisor, &serve/0)
        send(reply_to, {:task, pid})
        serve()
    end
  end
end
