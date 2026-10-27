defmodule Tymeslot.Infrastructure.Tasks do
  @moduledoc """
  Spawns tasks that carry their caller's context.

  A task is a new process, and a new process starts with no Logger metadata
  and no ErrorTracker context: its log lines lose the `correlation_id` that
  ties them to the request or job that started it, and a crash in it is
  recorded with no user, request or job attached. Each function here mirrors
  the `Task` or `Task.Supervisor` function of the same name, capturing the
  caller's context with `ErrorTracking.capture_context/0`, and its Gettext
  locale, and restoring both in the task before the task's function runs.

  Every task in the application is spawned through this module;
  `CredoChecks.TaskSpawnBoundary` flags a direct `Task` or `Task.Supervisor`
  spawn anywhere else under `lib/`, and a LiveView `start_async` whose
  function is not wrapped in `with_context/1`. Awaiting, yielding and shutting a task
  down are unchanged, so `Task.await/2`, `Task.yield/2` and `Task.shutdown/2`
  are still called directly.

  Only runtime calls to `ErrorTracking` are made here: modules across the
  application call this one, and a compile-time dependency would tie their
  recompilation to the error tracking code.
  """

  alias Tymeslot.Infrastructure.ErrorTracking

  @doc "`Task.async/1`, carrying the caller's context."
  @spec async((-> any())) :: Task.t()
  def async(fun) when is_function(fun, 0), do: Task.async(with_caller_context(fun))

  @doc "`Task.start/1`, carrying the caller's context."
  @spec start((-> any())) :: {:ok, pid()}
  def start(fun) when is_function(fun, 0), do: Task.start(with_caller_context(fun))

  @doc """
  Returns `fun` wrapped to run with the caller's context, for a process this
  module does not spawn: a LiveView's `start_async/3`, or a server that runs
  a function on behalf of the process that handed it over. The context is
  captured here, in the caller, not where the function eventually runs.
  """
  @spec with_context((-> result)) :: (-> result) when result: var
  def with_context(fun) when is_function(fun, 0), do: with_caller_context(fun)

  @doc "`Task.Supervisor.async/2`, carrying the caller's context."
  @spec async(Supervisor.supervisor(), (-> any())) :: Task.t()
  def async(supervisor, fun) when is_function(fun, 0),
    do: Task.Supervisor.async(supervisor, with_caller_context(fun))

  @doc "`Task.Supervisor.async_nolink/2`, carrying the caller's context."
  @spec async_nolink(Supervisor.supervisor(), (-> any())) :: Task.t()
  def async_nolink(supervisor, fun) when is_function(fun, 0),
    do: Task.Supervisor.async_nolink(supervisor, with_caller_context(fun))

  @doc "`Task.Supervisor.start_child/2`, carrying the caller's context."
  @spec start_child(Supervisor.supervisor(), (-> any())) :: DynamicSupervisor.on_start_child()
  def start_child(supervisor, fun) when is_function(fun, 0),
    do: Task.Supervisor.start_child(supervisor, with_caller_context(fun))

  @doc "`Task.async_stream/3`, carrying the caller's context into every task."
  @spec async_stream(Enumerable.t(), (term() -> term()), keyword()) :: Enumerable.t()
  def async_stream(enumerable, fun, options \\ []) when is_function(fun, 1),
    do: Task.async_stream(enumerable, with_caller_context(fun), options)

  @doc "`Task.Supervisor.async_stream_nolink/4`, carrying the caller's context into every task."
  @spec async_stream_nolink(
          Supervisor.supervisor(),
          Enumerable.t(),
          (term() -> term()),
          keyword()
        ) ::
          Enumerable.t()
  def async_stream_nolink(supervisor, enumerable, fun, options \\ []) when is_function(fun, 1),
    do:
      Task.Supervisor.async_stream_nolink(
        supervisor,
        enumerable,
        with_caller_context(fun),
        options
      )

  # Captured here, in the caller; restored in the task. The Gettext locale
  # is process state too, so text a task builds (a refusal, a flash) is in
  # the caller's language rather than the default.
  defp with_caller_context(fun) when is_function(fun, 0) do
    context = capture()

    fn ->
      restore(context)
      fun.()
    end
  end

  defp with_caller_context(fun) when is_function(fun, 1) do
    context = capture()

    fn element ->
      restore(context)
      fun.(element)
    end
  end

  defp capture, do: {ErrorTracking.capture_context(), Gettext.get_locale(TymeslotWeb.Gettext)}

  defp restore({error_context, locale}) do
    ErrorTracking.restore_context(error_context)
    Gettext.put_locale(TymeslotWeb.Gettext, locale)
  end
end
