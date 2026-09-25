defmodule CredoChecks.ObanQueueDeclared do
  @moduledoc """
  Flags `use Oban.Worker, queue: :some_queue` where `:some_queue` names a
  queue that is not configured anywhere.

  A typo in a queue name produces no error, no warning, and no crash: Oban
  happily inserts the job, nothing ever dequeues it, and it sits `available`
  forever. Nothing in the request path, the test suite, or production
  monitoring notices, which is the entire reason this check exists.

  ## Where queues are configured

  Core declares the base set under `config :tymeslot, :oban_queues` in
  `config/config.exs`. The SaaS overlay extends or overrides it through
  `config :tymeslot, :oban_additional_queues`, the extension point Core
  reserves for exactly this purpose. Both are read at runtime rather than at
  config time by `Tymeslot.Infrastructure.ObanQueues.build/1` —
  `config/dev.exs` has a comment on why: Oban's configuration function runs
  after every config file has already been applied, so the merge cannot
  happen at compile time.

  ## How it works

  Neither `:oban_queues` nor `:oban_additional_queues` is visible to Credo
  from the source file it happens to be analysing — they live in a sibling
  config file, not in the worker module. This check reads
  `config/config.exs` relative to the working directory Credo runs in, plus
  `../tymeslot/config/config.exs`, so that running inside the SaaS repo still
  finds Core's base queue set from the sibling checkout. Both files are
  parsed, not evaluated, and only the literal atom keys of a literal
  `config :tymeslot, :oban_queues, ...` or
  `config :tymeslot, :oban_additional_queues, ...` call are collected —
  nothing else in either file is interpreted or executed.

  The merged set is cached, keyed by the resolved config paths, in an Agent
  registered under this module's name, so the parse happens once per Credo
  session even though Credo runs checks in parallel across many source files
  at once. `Agent.start/2` (not `start_link/2`) is used so the cache outlives
  whichever parallel Task happens to populate it first — the same problem
  `CredoChecks.MigrationConstraintSafety` solves for its own migration scan.

  **Fails open.** If neither config file can be read, or neither key turns
  up in either of them, the check reports nothing at all rather than
  flagging every worker in the codebase. A check that goes noisy the moment
  a path assumption breaks is worse than one that goes quiet.

  A `queue:` value that is not a literal atom (a module attribute, a
  variable) is left alone rather than guessed at: every worker in this
  codebase currently uses a literal atom, so this costs nothing today.

  ## Examples

      # Bad — :report is declared in neither :oban_queues nor
      # :oban_additional_queues
      defmodule Tymeslot.Workers.WeeklyReportWorker do
        use Oban.Worker, queue: :report

        def perform(_job), do: :ok
      end

      # Good — :emails is declared under :oban_queues in config/config.exs
      defmodule Tymeslot.Workers.ReminderEmailWorker do
        use Oban.Worker, queue: :emails, max_attempts: 5

        def perform(_job), do: :ok
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      queue_names: nil,
      config_paths: ["config/config.exs", "../tymeslot/config/config.exs"]
    ],
    explanations: [
      check: """
      use Oban.Worker declares a queue that is not configured anywhere.

      Oban inserts jobs into any queue name without validating it. A queue
      nothing dequeues from is silent: jobs sit `available` forever with no
      error, no warning, and no crash. Add the queue to :oban_queues (Core)
      or :oban_additional_queues (the overlay's extension point) in
      config/config.exs, or fix the typo.
      """,
      params: [
        queue_names:
          "Override the configured queue set entirely, skipping config-file " <>
            "discovery. Mainly useful for tests; leave unset in .credo.exs so the " <>
            "real configuration is read.",
        config_paths:
          "Config files parsed for :oban_queues / :oban_additional_queues, " <>
            "relative to the working directory Credo runs in. Defaults to this " <>
            "repo's own config.exs plus the sibling Core checkout's, so the check " <>
            "works unchanged from either repo."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    if lib_file?(source_file.filename) do
      case configured_queue_names(params) do
        nil ->
          []

        queue_names ->
          issue_meta = IssueMeta.for(source_file, params)
          Code.prewalk(source_file, &traverse(&1, &2, issue_meta, queue_names))
      end
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Scope
  # ---------------------------------------------------------------------------

  defp lib_file?(filename), do: "lib" in Path.split(filename)

  # ---------------------------------------------------------------------------
  # Traversal
  # ---------------------------------------------------------------------------

  defp traverse(
         {:use, meta, [{:__aliases__, _am, [:Oban, :Worker]}, opts]} = ast,
         issues,
         issue_meta,
         queue_names
       )
       when is_list(opts) do
    case Keyword.fetch(opts, :queue) do
      {:ok, queue} when is_atom(queue) and not is_nil(queue) ->
        if MapSet.member?(queue_names, queue) do
          {ast, issues}
        else
          {ast, [build_issue(issue_meta, meta[:line], queue) | issues]}
        end

      _no_literal_queue ->
        {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta, _queue_names), do: {ast, issues}

  defp build_issue(issue_meta, line_no, queue) do
    format_issue(issue_meta,
      message:
        "Oban worker declares queue #{inspect(queue)}, which is not configured. Jobs " <>
          "enqueued to it will sit `available` forever with nothing to dequeue them. Add " <>
          "#{inspect(queue)} to :oban_queues or :oban_additional_queues in config/config.exs.",
      line_no: line_no,
      trigger: "queue: #{inspect(queue)}"
    )
  end

  # ---------------------------------------------------------------------------
  # Queue name discovery
  # ---------------------------------------------------------------------------

  defp configured_queue_names(params) do
    case Params.get(params, :queue_names, __MODULE__) do
      nil -> discovered_queue_names(params)
      names -> MapSet.new(names)
    end
  end

  defp discovered_queue_names(params) do
    paths = Params.get(params, :config_paths, __MODULE__)

    ensure_agent()
    Agent.get_and_update(__MODULE__, &cached_names(&1, paths))
  end

  # Agent.start/2 (never start_link/2): the process must outlive whichever
  # parallel Task first calls this, exactly as CredoChecks.MigrationConstraintSafety
  # relies on for its own once-per-session scan.
  defp ensure_agent do
    case Agent.start(fn -> %{} end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp cached_names(cache, paths) do
    case Map.fetch(cache, paths) do
      {:ok, names} ->
        {names, cache}

      :error ->
        names = merged_queue_names(paths)
        {names, Map.put(cache, paths, names)}
    end
  end

  # ---------------------------------------------------------------------------
  # Config-file parsing
  # ---------------------------------------------------------------------------

  defp merged_queue_names(paths) do
    base = collect_keys(paths, :oban_queues)
    additional = collect_keys(paths, :oban_additional_queues)

    case base ++ additional do
      [] -> nil
      keys -> MapSet.new(keys)
    end
  end

  defp collect_keys(paths, config_key) do
    Enum.flat_map(paths, &keys_from_path(&1, config_key))
  end

  defp keys_from_path(path, config_key) do
    case File.read(path) do
      {:ok, source} -> keys_from_source(source, config_key)
      {:error, _reason} -> []
    end
  end

  # `Code` is aliased to `Credo.Code` above, so the standard library module is
  # reached through its full name here.
  defp keys_from_source(source, config_key) do
    case Elixir.Code.string_to_quoted(source) do
      {:ok, ast} -> collect_config_keys(ast, config_key)
      {:error, _reason} -> []
    end
  end

  defp collect_config_keys(ast, config_key) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:config, _meta, [:tymeslot, key, value]} = node, acc when key == config_key ->
          {node, literal_atom_keys(value) ++ acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp literal_atom_keys(list) when is_list(list) do
    Enum.flat_map(list, fn
      {key, _val} when is_atom(key) -> [key]
      _other -> []
    end)
  end

  defp literal_atom_keys(_other), do: []
end
