defmodule Tymeslot.Infrastructure.ErrorTracking.UnmatchedEvent do
  @moduledoc """
  Recognises a LiveView or LiveComponent sent an event that none of its
  `handle_event/3` clauses matches.

  The client chooses both the event name and the component it targets, so
  any signed-in user can produce this crash on demand with a forged socket
  frame. It is bad input, not a fault in the system, and is neither stored
  nor alerted on (`Tymeslot.Infrastructure.ErrorTracking.Ignorer`), nor
  recorded by `Tymeslot.Infrastructure.CrashReporter`, which logs a warning
  instead.

  The rule reads only what ErrorTracker keeps of the exception, its kind and
  message, so the Ignorer and the crash reporter apply the same one. A
  `FunctionClauseError`'s message names the function whose clauses did not
  match: `"no function clause matching in TymeslotWeb.DashboardLive.handle_event/3"`.
  When that function is the `handle_event/3` of a LiveView or LiveComponent,
  no clause accepted the event. A clause that matched and then failed raises
  something else, or a `FunctionClauseError` naming the function it called,
  and is recorded as usual.

  Every function here is total, since its callers run in telemetry and
  `:logger` handlers: anything unexpected answers `false`, which means
  "record it".
  """

  @message ~r/\Ano function clause matching in ([A-Za-z0-9_.]+)\.handle_event\/3/
  @function_clause_error Atom.to_string(FunctionClauseError)

  @doc """
  Returns true for an exception, known as ErrorTracker records it (`kind` is
  the exception module's name, `reason` its message), that says no
  `handle_event/3` clause of a LiveView or LiveComponent matched.
  """
  @spec error?(String.t(), String.t()) :: boolean()
  def error?(@function_clause_error, reason) when is_binary(reason) do
    case Regex.run(@message, reason) do
      [_match, module_name] -> live_module?(module_name)
      nil -> false
    end
  end

  def error?(_kind, _reason), do: false

  @doc "Like `error?/2`, for the exception itself."
  @spec exception?(term()) :: boolean()
  def exception?(%FunctionClauseError{} = exception),
    do: error?(@function_clause_error, Exception.message(exception))

  def exception?(_other), do: false

  # Resolves the name without creating an atom: a module that is not loaded
  # has no atom yet, and is not a LiveView of this application anyway.
  defp live_module?(module_name) do
    module = String.to_existing_atom("Elixir." <> module_name)
    Code.ensure_loaded?(module) and function_exported?(module, :__live__, 0)
  rescue
    # No atom means no such module: an expected answer, not a failure.
    # credo:disable-for-next-line CredoChecks.NoSwallowedException
    ArgumentError -> false
  end
end
