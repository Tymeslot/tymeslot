defmodule Tymeslot.Workers.Bounded do
  @moduledoc """
  Runs a job's work with a deadline.

  An Oban worker that waits on a provider (a calendar server, a mail relay, a
  video API) cannot let a hung connection hold its queue slot until Oban's
  own timeout kills the job from outside, where the worker cannot decide
  between retrying, snoozing and giving up. The work runs in a supervised
  task, carrying the job's context (`Tymeslot.Infrastructure.Tasks`), and is
  stopped at the deadline.

  The task runs with `$callers` set, so the Ecto sandbox and Mox allowances
  of the process that runs the job reach it in tests as in production: there
  is no separate synchronous path for tests. It is not linked, so a crash
  comes back to the worker as a value: a linked crash would kill the job
  with its raw exit reason, which Oban stores and which can carry a client's
  credentials.
  """

  alias Tymeslot.Infrastructure.Tasks

  @doc """
  Runs `fun` and returns `{:ok, result}`; `{:exit, reason}` if it crashed;
  or `:timeout` if it has not returned within `timeout_ms`, in which case it
  is stopped.

  A worker turning `{:exit, reason}` into a job error must redact `reason`
  (`LogFormat.reason/1`) before it reaches the job's stored errors.
  """
  @spec run((-> result), timeout()) :: {:ok, result} | {:exit, term()} | :timeout
        when result: term()
  def run(fun, timeout_ms) when is_function(fun, 0) do
    task = Tasks.async_nolink(Tymeslot.TaskSupervisor, fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      nil -> :timeout
      outcome -> outcome
    end
  end
end
