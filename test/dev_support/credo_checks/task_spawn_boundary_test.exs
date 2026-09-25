Code.require_file(
  "dev_support/credo_checks/task_spawn_boundary.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.TaskSpawnBoundaryTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.TaskSpawnBoundary

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source, filename \\ "lib/tymeslot/some_context.ex") do
    source
    |> to_source_file(filename)
    |> run_check(TaskSpawnBoundary)
  end

  describe "flagged cases" do
    test "flags Task.async/1" do
      """
      defmodule Tymeslot.SomeContext do
        def run, do: Task.async(fn -> :ok end)
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "Task.async" end)
    end

    test "flags a piped Task.Supervisor.async_stream_nolink" do
      """
      defmodule Tymeslot.SomeContext do
        def run(items) do
          Tymeslot.TaskSupervisor
          |> Task.Supervisor.async_stream_nolink(items, &work/1)
          |> Enum.to_list()
        end
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.trigger == "Task.Supervisor.async_stream_nolink"
      end)
    end

    test "flags Task.Supervisor.start_child/2 in the web layer" do
      """
      defmodule TymeslotWeb.SomeLive do
        def run, do: Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn -> :ok end)
      end
      """
      |> check("lib/tymeslot_web/live/some_live.ex")
      |> assert_issue(fn issue -> assert issue.trigger == "Task.Supervisor.start_child" end)
    end

    test "flags a capture of Task.start/1" do
      """
      defmodule Tymeslot.SomeContext do
        def spawner, do: &Task.start/1
      end
      """
      |> check()
      |> assert_issue(fn issue -> assert issue.trigger == "Task.start" end)
    end

    test "flags each spawn in a file" do
      """
      defmodule Tymeslot.SomeContext do
        def one, do: Task.Supervisor.async(Tymeslot.TaskSupervisor, fn -> 1 end)
        def two, do: Task.Supervisor.async_nolink(Tymeslot.TaskSupervisor, fn -> 2 end)
      end
      """
      |> check()
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end
  end

  describe "passing cases" do
    test "allows the Tasks wrapper everywhere" do
      """
      defmodule Tymeslot.SomeContext do
        alias Tymeslot.Infrastructure.Tasks

        def run do
          task = Tasks.async(Tymeslot.TaskSupervisor, fn -> :ok end)
          Task.await(task)
        end
      end
      """
      |> check()
      |> refute_issues()
    end

    test "allows functions that only handle a spawned task" do
      """
      defmodule Tymeslot.SomeContext do
        def wait(task) do
          Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)
          Task.await_many([task])
        end
      end
      """
      |> check()
      |> refute_issues()
    end

    test "allows direct spawns inside the wrapper itself" do
      """
      defmodule Tymeslot.Infrastructure.Tasks do
        def async(fun), do: Task.async(fun)
      end
      """
      |> check("lib/tymeslot/infrastructure/tasks.ex")
      |> refute_issues()
    end

    test "allows direct spawns in mix tasks and tests" do
      source = """
      defmodule Mix.Tasks.Something do
        def run(items), do: Task.async_stream(items, &IO.inspect/1)
      end
      """

      source |> check("lib/mix/tasks/something.ex") |> refute_issues()
      source |> check("test/some_test.exs") |> refute_issues()
    end

    test "allows a file named in :allowed" do
      """
      defmodule Tymeslot.SomeContext do
        def run, do: Task.async(fn -> :ok end)
      end
      """
      |> to_source_file("lib/tymeslot/some_context.ex")
      |> run_check(TaskSpawnBoundary, allowed: ["lib/tymeslot/some_context.ex"])
      |> refute_issues()
    end
  end
end
