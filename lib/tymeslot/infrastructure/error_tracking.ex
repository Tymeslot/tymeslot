defmodule Tymeslot.Infrastructure.ErrorTracking do
  @moduledoc """
  The application's entry point to error tracking.

  ErrorTracker stores every exception with the context of the process that
  raised it. Its own integrations contribute the request, LiveView and job
  details; this module contributes the keys that tie an occurrence to a user
  and to the log lines around it: `user_id`, `request_id` and
  `correlation_id`.

  Those keys are also Logger metadata, so `put_context/1` sets both at once.
  Setting them anywhere else, in one place and not the other, is how a log
  line and a stored exception from the same request end up disagreeing about
  who made it.
  """

  @direct_report_key :tymeslot_error_tracking_direct_report

  @doc """
  Sets `context` as Logger metadata and as ErrorTracker context for the
  current process.

  A `nil` value clears the key from Logger metadata and records it as `nil`
  in the error context, so resetting a key on a reused process cannot leave
  the previous request's value behind in either. ErrorTracker's context keys
  are strings (its own are `"request.path"`, `"job.args"` and so on), so the
  atom keys given here are stored as strings.
  """
  @spec put_context(keyword()) :: :ok
  def put_context(context) when is_list(context) do
    Logger.metadata(context)

    ErrorTracker.set_context(
      Map.new(context, fn {key, value} -> {Atom.to_string(key), value} end)
    )

    :ok
  end

  @doc """
  Returns the ErrorTracker context of the current process: the keys set by
  `put_context/1` and by ErrorTracker's own integrations (`"request.*"`,
  `"live_view.*"`, `"job.*"`).
  """
  @spec current_context() :: map()
  def current_context, do: ErrorTracker.get_context()

  @doc """
  Runs `fun`, marking every ErrorTracker report made inside it as a direct
  report: an exception the calling process handled and reported itself,
  and survives.

  `Tymeslot.Infrastructure.CrashReporter` remembers what ErrorTracker
  recorded in a process so that the crash log which follows an integration's
  report is not recorded a second time. A process that reports an exception
  and carries on must not leave that memory behind, or a later crash with
  the same kind and message would be taken for the one already recorded. Any
  code reporting directly wraps its `ErrorTracker.report/3` call in this.
  """
  @spec with_direct_report((-> result)) :: result when result: var
  def with_direct_report(fun) when is_function(fun, 0) do
    previous = Process.put(@direct_report_key, true)

    try do
      fun.()
    after
      if previous,
        do: Process.put(@direct_report_key, previous),
        else: Process.delete(@direct_report_key)
    end
  end

  @doc "Returns true inside `with_direct_report/1` in the calling process."
  @spec direct_report?() :: boolean()
  def direct_report?, do: Process.get(@direct_report_key) == true
end
