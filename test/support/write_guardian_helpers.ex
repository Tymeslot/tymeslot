defmodule Tymeslot.Test.WriteGuardianHelpers do
  @moduledoc """
  Keeps a calendar grid write guardian (`Tymeslot.CalendarGrid.WriteGuardian`)
  from outliving the test that started it.

  A guardian runs under the application's supervisor, not the test's, and
  takes over the grid's queue when the test's LiveView goes at the end of
  the test. Left alone, it would go on making writes, or saving them for a
  later sync, under a test that has finished, against a sandbox that is
  gone and stubs that may belong to the next test.
  """

  alias ExUnit.Callbacks
  alias Tymeslot.CalendarGrid.WriteGuardian

  @doc """
  Kills, on exit of the calling test, every guardian started on its behalf
  (whose `$callers` name it). Killed rather than stopped, so that none of
  them tries to save its queue on the way out.
  """
  @spec stop_on_exit() :: :ok
  def stop_on_exit do
    test_pid = self()
    Callbacks.on_exit(fn -> kill_guardians_of(test_pid) end)
  end

  @doc "Kills every guardian started on behalf of `test_pid`."
  @spec kill_guardians_of(pid()) :: :ok
  def kill_guardians_of(test_pid) do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(WriteGuardian.supervisor()),
        is_pid(pid),
        started_for?(pid, test_pid) do
      Process.exit(pid, :kill)
    end

    :ok
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
