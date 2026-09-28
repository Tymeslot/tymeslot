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
  alias Tymeslot.Infrastructure.ErrorTracking.ReasonScrubber
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks

  require Logger

  @direct_report_key :tymeslot_error_tracking_direct_report

  # The keys this module keeps in step between Logger metadata and the
  # ErrorTracker context.
  @context_keys [:user_id, :request_id, :correlation_id]

  @opaque captured_context :: {map(), keyword()}

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
  Captures the calling process's context, for `restore_context/1` to set in
  another process doing work on its behalf: the whole ErrorTracker context,
  and the `user_id`, `request_id` and `correlation_id` Logger metadata.
  """
  @spec capture_context() :: captured_context()
  def capture_context,
    do: {current_context(), Keyword.take(Logger.metadata(), @context_keys)}

  @doc """
  Sets a context captured by `capture_context/0` in the current process, so
  its log lines and any exception it raises tie back to the process that
  captured it.
  """
  @spec restore_context(captured_context()) :: :ok
  def restore_context({tracker_context, metadata}) do
    ErrorTracker.set_context(tracker_context)
    put_context(metadata)
  end

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

  @doc """
  Whether error tracking records anything: ErrorTracker's own `enabled`
  switch, set from `ERROR_TRACKING_ENABLED` at boot. Read on every call, as
  ErrorTracker reads it on every report, so the crash reporter and
  `report_error/3` stop doing work the moment it is off.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:error_tracker, :enabled, true) not in [false, nil]

  @doc "Returns true inside `with_direct_report/1` in the calling process."
  @spec direct_report?() :: boolean()
  def direct_report?, do: Process.get(@direct_report_key) == true

  @doc """
  Records a failure that was handled but not expected, and logs it at
  `:error`. Always returns `:ok`, and never raises: a failure to record is
  logged instead. With error tracking switched off (`enabled?/0`) it only
  logs.

  For a bug or an outage the caller recovered from (a rescued exception, an
  `{:error, reason}` nothing anticipated), not for expected failures such as
  invalid input or a provider refusing a request for a known reason.

  Inside an Oban job, ErrorTracker's Oban integration records a job that
  raises or returns `{:error, reason}`, as the job's outcome: without the
  stacktrace of the code that failed. A failure reported here that then also
  fails the job is therefore recorded twice, as two separate errors: this
  report, with the failing call site, and the job's, with none. Report here
  when the job goes on to succeed (the integration then records nothing), or
  when the call site is worth the second record; do not report a failure the
  job is about to return or raise for no other reason.

  `exception_or_reason` is either an exception, reported as itself, or any
  other term, wrapped in `Tymeslot.Infrastructure.ErrorTracking.HandledError`.
  ErrorTracker groups occurrences by exception module and the top frame of
  `stacktrace` in this application, so every reason reported from one call
  site is one error, and `HandledError`'s message is the reason's shape rather
  than its data. The full reason, bounded, goes into the occurrence's context
  as `"error.reason"`; ids and other variable data belong in `context` too,
  never in a message.

  ErrorTracker stores an exception's message as it is, unredacted, and many
  messages embed the term that failed (`KeyError`, `MatchError`,
  `FunctionClauseError`). Where that term can hold a decrypted credential,
  report `{:raised, exception.__struct__}` with the exception's stacktrace
  instead, so the error is known by its module alone.

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

    log_handled_error(exception, exception_or_reason, context)

    if enabled?(),
      do: record(exception, stacktrace, tracker_context(exception, context)),
      else: :ok
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

  # The reason is rendered from the term the caller gave, through
  # `LogFormat.reason/1`, so a credential inside it is redacted by key before
  # it becomes text; `HandledError`'s own copy is a plain `inspect`. The
  # message gets the scrub its stored copy gets.
  defp log_handled_error(exception, exception_or_reason, context) do
    metadata =
      context
      |> Enum.filter(fn {key, _value} -> is_atom(key) end)
      |> Keyword.new()
      |> Keyword.merge(
        error_kind: inspect(exception.__struct__),
        error_message: ReasonScrubber.scrub(Exception.message(exception)),
        reason: LogFormat.reason(exception_or_reason)
      )

    Logger.error("Handled an unexpected error", metadata)
  end

  defp record(exception, stacktrace, context) do
    if ErrorTrackingQueries.in_transaction?() do
      offload(exception, stacktrace, context)
    else
      with_direct_report(fn -> ErrorTracker.report(exception, stacktrace, context) end)
    end

    :ok
  end

  # The task runs with the caller's ErrorTracker context, which `Tasks`
  # carries into it. It exits once the report is made, so no dedup memory is
  # left behind to guard against.
  defp offload(exception, stacktrace, context) do
    {:ok, _pid} =
      Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
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
