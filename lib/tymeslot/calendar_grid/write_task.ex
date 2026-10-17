defmodule Tymeslot.CalendarGrid.WriteTask do
  @moduledoc """
  Runs one calendar write in a supervised task and sends `{tag, result}` to
  the process that started it (a calendar's LiveView) once it returns.

  If the write raises, throws or exits, `{tag, crash_result}` is sent
  instead, so the handler for `tag` still hears back and an optimistic
  change on screen is never left standing without an answer.

  With `report_to_guardian: true`, `{tag, result}` goes first to the
  LiveView's `Tymeslot.CalendarGrid.WriteGuardian`, looked up once the write
  returns, which finishes the queued writes should the LiveView, or its
  calendar, be gone by then.
  """

  require Logger

  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks

  @spec start(atom(), (-> term()), term(), keyword()) :: :ok
  def start(tag, fun, crash_result, opts \\ []) when is_atom(tag) and is_function(fun, 0) do
    owner = self()
    report_to_guardian? = Keyword.get(opts, :report_to_guardian, false)

    {:ok, _pid} =
      Tasks.start_child(Tymeslot.TaskSupervisor, fn ->
        message = {tag, run_guarded(tag, fun, crash_result)}

        if report_to_guardian?,
          do: WriteGuardian.report(owner, message),
          else: send(owner, message)
      end)

    :ok
  end

  defp run_guarded(tag, fun, crash_result) do
    fun.()
  catch
    kind, reason ->
      Logger.error("Calendar grid task crashed",
        task: tag,
        kind: kind,
        error: LogFormat.reason(reason),
        stacktrace: LogFormat.stacktrace(__STACKTRACE__)
      )

      crash_result
  end
end
