defmodule CredoChecks.TaskSpawnBoundary do
  @moduledoc """
  Flags tasks spawned without `Tymeslot.Infrastructure.Tasks`, and LiveView
  async work that runs without its caller's context.

  A task is a new process and starts with no Logger metadata and no
  ErrorTracker context. `Tymeslot.Infrastructure.Tasks` carries the
  caller's `correlation_id`, `user_id`, `request_id` and error context into
  the task; a task spawned with `Task` or `Task.Supervisor` directly loses
  them silently, so its log lines no longer tie back to the request or job
  that started it and its crashes are recorded with no user attached.

  Flagged under `lib/` only:

    * the spawning functions of `Task` (`async`, `async_stream`, `start`) and
      of `Task.Supervisor` (`async`, `async_nolink`, `async_stream`,
      `async_stream_nolink`, `start_child`), including function captures
      such as `&Task.async/1`. Functions that only work with a task already
      spawned (`Task.await/2`, `Task.yield/2`, `Task.shutdown/2` and the
      like) are not flagged.
    * a LiveView `start_async` or `assign_async` whose function is not
      wrapped in `Tasks.with_context/1`. LiveView runs the function in a
      process it spawns itself, so the wrapper is the only way the LiveView's
      correlation id reaches it.

  ## Excluded files

  - `lib/tymeslot/infrastructure/tasks.ex`: the wrapper itself
  - Files under `lib/mix/tasks/`: dev-only tooling that runs outside any
    request or job, so there is no context to carry
  - Test files
  - An `:allowed` param (list of filename substrings), for any future
    caller with a genuine, reviewed reason to spawn directly:

        {CredoChecks.TaskSpawnBoundary, [allowed: ["lib/tymeslot/some/exception.ex"]]}

  ## Examples

      # Bad: the task loses its caller's correlation id
      Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn -> notify(user) end)

      # Good
      Tasks.start_child(Tymeslot.TaskSupervisor, fn -> notify(user) end)

      # Bad: the async function runs without the LiveView's correlation id
      start_async(socket, :load, fn -> load(user) end)

      # Good
      start_async(socket, :load, Tasks.with_context(fn -> load(user) end))
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [allowed: []],
    explanations: [
      check: """
      Tasks must be spawned through `Tymeslot.Infrastructure.Tasks`, which
      carries the caller's correlation id, user and error context into the
      task. A task spawned with `Task` or `Task.Supervisor` directly runs
      without them, and so does a LiveView `start_async` or `assign_async`
      function not wrapped in `Tasks.with_context/1`.
      """,
      params: [
        allowed: "List of filename substrings allowed to spawn tasks directly."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @task_spawns [:async, :async_stream, :start]
  @supervisor_spawns [:async, :async_nolink, :async_stream, :async_stream_nolink, :start_child]
  @live_view_asyncs [:start_async, :assign_async]
  @definitions [:def, :defp]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename
    allowed = Params.get(params, :allowed, __MODULE__)

    if excluded?(filename, allowed) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp excluded?(filename, allowed) do
    not lib_file?(filename) or
      String.ends_with?(filename, "/infrastructure/tasks.ex") or
      String.contains?(filename, "lib/mix/tasks/") or
      test_file?(filename) or
      Enum.any?(allowed, &String.contains?(filename, &1))
  end

  defp lib_file?(filename),
    do: String.contains?(filename, "/lib/") or String.starts_with?(filename, "lib/")

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.starts_with?(filename, "test/") or
      String.ends_with?(filename, "_test.exs")
  end

  # A capture (`&Task.async/1`) contains the same call node with no
  # arguments, so it is caught here too.
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Task]}, function]}, meta, args} = ast,
         issues,
         issue_meta
       )
       when is_list(args) and function in @task_spawns do
    {ast, [issue(issue_meta, meta[:line], "Task.#{function}") | issues]}
  end

  defp traverse(
         {{:., _, [{:__aliases__, _, [:Task, :Supervisor]}, function]}, meta, args} = ast,
         issues,
         issue_meta
       )
       when is_list(args) and function in @supervisor_spawns do
    {ast, [issue(issue_meta, meta[:line], "Task.Supervisor.#{function}") | issues]}
  end

  # A definition named like a LiveView async function is not a call to one:
  # its head is dropped so the walk does not mistake it for a call.
  defp traverse({definition, meta, [head | body]}, issues, _issue_meta)
       when definition in @definitions do
    if defines_live_view_async?(head),
      do: {{definition, meta, [nil | body]}, issues},
      else: {{definition, meta, [head | body]}, issues}
  end

  defp traverse({function, meta, args} = ast, issues, issue_meta)
       when function in @live_view_asyncs and is_list(args) do
    {ast, live_view_async_issues(issue_meta, meta, function, args, issues)}
  end

  defp traverse(
         {{:., _, [{:__aliases__, _, [_ | _] = parts}, function]}, meta, args} = ast,
         issues,
         issue_meta
       )
       when function in @live_view_asyncs and is_list(args) do
    if List.last(parts) == :LiveView,
      do: {ast, live_view_async_issues(issue_meta, meta, function, args, issues)},
      else: {ast, issues}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp defines_live_view_async?({:when, _, [head | _guards]}), do: defines_live_view_async?(head)
  defp defines_live_view_async?({name, _, _args}), do: name in @live_view_asyncs
  defp defines_live_view_async?(_head), do: false

  defp live_view_async_issues(issue_meta, meta, function, args, issues) do
    if with_context?(async_function(args)),
      do: issues,
      else: [live_view_async_issue(issue_meta, meta[:line], function) | issues]
  end

  # The function is the last argument, or the one before a trailing options
  # list.
  defp async_function(args) do
    case Enum.reverse(args) do
      [options, function | _rest] when is_list(options) -> function
      [function | _rest] -> function
      [] -> nil
    end
  end

  defp with_context?({{:., _, [{:__aliases__, _, parts}, :with_context]}, _, [_fun]}),
    do: List.last(parts) == :Tasks

  defp with_context?(_function), do: false

  defp live_view_async_issue(issue_meta, line_no, function) do
    format_issue(issue_meta,
      message:
        "`#{function}` runs its function without the LiveView's correlation id and error " <>
          "context. Wrap the function in `Tymeslot.Infrastructure.Tasks.with_context/1`.",
      line_no: line_no,
      trigger: Atom.to_string(function)
    )
  end

  defp issue(issue_meta, line_no, trigger) do
    format_issue(issue_meta,
      message:
        "`#{trigger}` spawns a task without its caller's correlation id and error " <>
          "context. Use the function of the same name in `Tymeslot.Infrastructure.Tasks`.",
      line_no: line_no,
      trigger: trigger
    )
  end
end
