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

  `report_error/3` records a failure the code handled but did not expect: a
  bug or an outage it recovered from with a fallback, which would otherwise
  be visible only as a log line.
  """

  alias Tymeslot.Infrastructure.ErrorTracking.ErrorTrackingQueries
  alias Tymeslot.Infrastructure.ErrorTracking.HandledError

  require Logger

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

  @doc """
  Records a failure that was handled but not expected, and logs it at
  `:error`. Always returns `:ok`, and never raises: a failure to record is
  logged instead.

  For a bug or an outage the caller recovered from (a rescued exception, an
  `{:error, reason}` nothing anticipated), not for expected failures such as
  invalid input or a provider refusing a request for a known reason. Inside an
  Oban job, a failure the job returns as `{:error, reason}` is already recorded
  by ErrorTracker's Oban integration and must not be reported here as well.

  `exception_or_reason` is either an exception, reported as itself, or any
  other term, wrapped in `Tymeslot.Infrastructure.ErrorTracking.HandledError`.
  ErrorTracker groups occurrences by exception module and the top frame of
  `stacktrace` in this application, so every reason reported from one call
  site is one error, and `HandledError`'s message is the reason's shape rather
  than its data. The full reason, bounded, goes into the occurrence's context
  as `"error.reason"`; ids and other variable data belong in `context` too,
  never in a message.

  `stacktrace` is the rescued exception's `__STACKTRACE__`, or `nil` where
  there is none, in which case the caller's own stacktrace is used so the
  call site is still the error's source. ErrorTracker's source is a file and
  line, so each call site is its own error; a call in tail position has left
  its function's frame already, and the source is then the line that called
  that function.

  `context` is a map or keyword list, typically of ids (`meeting_id:`,
  `integration_id:`). It is added to the process's ErrorTracker context,
  which the Filter redacts before storing, and its atom keys are added to the
  log line's metadata.

  Inside a database transaction the report is made from a separate process:
  written on the transaction's connection, it would be rolled back with the
  work that failed, or refused outright once a database error has aborted
  the transaction.
  """
  @spec report_error(Exception.t() | term(), Exception.stacktrace() | nil, map() | keyword()) ::
          :ok
  def report_error(exception_or_reason, stacktrace, context \\ %{}) do
    exception = to_exception(exception_or_reason)
    stacktrace = stacktrace_or_caller(stacktrace)
    context = Map.new(context)

    log_handled_error(exception, context)
    record(exception, stacktrace, tracker_context(exception, context))
  rescue
    failure -> log_report_failure(failure)
  catch
    kind, _reason -> log_report_failure(kind)
  end

  defp to_exception(exception) when is_exception(exception), do: exception
  defp to_exception(reason), do: HandledError.exception(reason)

  defp stacktrace_or_caller(stacktrace) when is_list(stacktrace) and stacktrace != [],
    do: stacktrace

  # The frames of `Process.info/2` and of this module are dropped, so the top
  # frame is the caller of `report_error/3`.
  defp stacktrace_or_caller(_none) do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

    Enum.drop_while(stacktrace, fn {module, _fun, _arity, _location} ->
      module in [Process, __MODULE__]
    end)
  end

  defp tracker_context(%HandledError{reason: reason}, context),
    do: context |> string_keys() |> Map.put("error.reason", reason)

  defp tracker_context(_exception, context), do: string_keys(context)

  defp string_keys(context), do: Map.new(context, fn {key, value} -> {to_string(key), value} end)

  defp log_handled_error(exception, context) do
    metadata =
      context
      |> Enum.filter(fn {key, _value} -> is_atom(key) end)
      |> Keyword.new()
      |> Keyword.merge(
        error_kind: inspect(exception.__struct__),
        error_message: Exception.message(exception),
        reason: reason_for_log(exception)
      )

    Logger.error("Handled an unexpected error", metadata)
  end

  defp reason_for_log(%HandledError{reason: reason}), do: reason
  defp reason_for_log(exception), do: HandledError.bounded_inspect(exception)

  defp record(exception, stacktrace, context) do
    if ErrorTrackingQueries.in_transaction?() do
      offload(exception, stacktrace, Map.merge(current_context(), context))
    else
      with_direct_report(fn -> ErrorTracker.report(exception, stacktrace, context) end)
    end

    :ok
  end

  # The task has no ErrorTracker context of its own, so the caller's is
  # merged in first. It exits once the report is made, so no dedup memory is
  # left behind to guard against.
  defp offload(exception, stacktrace, context) do
    {:ok, _pid} =
      Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
        try do
          ErrorTracker.report(exception, stacktrace, context)
        rescue
          failure -> log_report_failure(failure)
        catch
          kind, _reason -> log_report_failure(kind)
        end
      end)

    :ok
  end

  # Names only the failure's module or kind: its message could carry the data
  # the report was about.
  defp log_report_failure(failure) do
    error = if is_exception(failure), do: inspect(failure.__struct__), else: inspect(failure)
    Logger.error("Failed to record a handled error", error: error)
    :ok
  end
end
