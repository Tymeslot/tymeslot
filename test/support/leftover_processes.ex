defmodule Tymeslot.Test.LeftoverProcesses do
  @moduledoc """
  Keeps the processes a test starts under the application's supervisors from
  outliving it.

  ExUnit stops what a test starts under its own supervisor, the LiveViews of
  `Phoenix.LiveViewTest` among them, before it runs the test's `on_exit`
  callbacks. It knows nothing of what the code under test starts elsewhere:
  the background tasks under `Tymeslot.TaskSupervisor` (a calendar grid's
  provider writes, an ad-hoc meeting's notifications), those under the
  error tracker's own supervisor (an error raised inside a transaction is
  recorded from a task, see `Tymeslot.Infrastructure.ErrorTracking`), and
  the grid's write guardians (`Tymeslot.CalendarGrid.WriteGuardian`), which
  take over the queue when the test's LiveView goes. Left alone, one goes on working after
  its test has ended. Once the test's sandbox owner has stopped, its next
  query finds the owner of the following test instead, if that test runs
  in shared mode, so it writes jobs, rows and emails into a test that never
  made them, against stubs that belong to that test too.

  A process counts as the test's when its `$callers` name the test process,
  which `Task.Supervisor` and the guardian both inherit from whoever started
  them.
  """

  alias ExUnit.Callbacks
  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.Infrastructure.ErrorTracking

  @doc """
  Kills, on exit of the calling test and before its sandbox owner stops,
  every process started on its behalf under the application's supervisors.
  Killed rather than stopped, so that no guardian tries to save its queue on
  the way out.

  Call it after the sandbox owner is started: `on_exit` callbacks run in the
  reverse order of registration, and this one has to run first.
  """
  @spec stop_on_exit() :: :ok
  def stop_on_exit do
    test_pid = self()
    Callbacks.on_exit(fn -> kill_processes_of(test_pid) end)
  end

  @doc "Kills every process started on behalf of `test_pid`, and waits until each is gone."
  @spec kill_processes_of(pid()) :: :ok
  def kill_processes_of(test_pid) do
    # Guardians first: each one starts tasks of its own.
    kill_all(guardians(), test_pid)
    kill_all(tasks(), test_pid)
  end

  defp tasks do
    Enum.flat_map(
      [Tymeslot.TaskSupervisor, ErrorTracking.task_supervisor()],
      &Task.Supervisor.children/1
    )
  end

  defp guardians do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(WriteGuardian.supervisor()),
        is_pid(pid),
        do: pid
  end

  defp kill_all(pids, test_pid) do
    pids
    |> Enum.filter(&started_for?(&1, test_pid))
    |> Enum.map(fn pid ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      ref
    end)
    |> Enum.each(fn ref ->
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    end)
  end

  defp started_for?(pid, test_pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, :"$callers", 0) do
          {_key, callers} -> test_pid in callers
          nil -> false
        end

      nil ->
        false
    end
  end
end
