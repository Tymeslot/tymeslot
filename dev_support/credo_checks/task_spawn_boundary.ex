defmodule CredoChecks.TaskSpawnBoundary do
  @moduledoc """
  Flags tasks spawned without `Tymeslot.Infrastructure.Tasks`.

  A task is a new process and starts with no Logger metadata and no
  ErrorTracker context. `Tymeslot.Infrastructure.Tasks` carries the
  caller's `correlation_id`, `user_id`, `request_id` and error context into
  the task; a task spawned with `Task` or `Task.Supervisor` directly loses
  them silently, so its log lines no longer tie back to the request or job
  that started it and its crashes are recorded with no user attached.

  Flagged under `lib/` only: the spawning functions of `Task` (`async`,
  `async_stream`, `start`, `start_link`) and of `Task.Supervisor` (`async`,
  `async_nolink`, `async_stream`, `async_stream_nolink`, `start_child`),
  including function captures such as `&Task.async/1`. Functions that only
  work with a task already spawned (`Task.await/2`, `Task.yield/2`,
  `Task.shutdown/2` and the like) are not flagged.

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
      without them.
      """,
      params: [
        allowed: "List of filename substrings allowed to spawn tasks directly."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @task_spawns [:async, :async_stream, :start, :start_link]
  @supervisor_spawns [:async, :async_nolink, :async_stream, :async_stream_nolink, :start_child]

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

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

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
