defmodule CredoChecks.MigrationConstraintSafety do
  @moduledoc """
  Flags migrations that add constraints to existing tables without a preceding
  data-preparation step (`execute`).

  This is an open-source project — we cannot see or validate user data before
  shipping. Every migration that adds a unique index, NOT NULL constraint, or
  check constraint must include a self-healing backfill or deduplication step
  in the same migration.

  ## What it detects

  - `create unique_index(...)` without a preceding `execute(...)` in the same
    `up/0` or `change/0` function
  - `modify :column, :type, null: false` without a preceding `execute(...)`

  Only `up/0` and `change/0` are analysed — constraints in `down/0` or helper
  functions are ignored. Constraints on tables created in the same migration
  are also ignored, since a freshly-created table has no pre-existing data.

  ## How it works

  Migration files are NOT included in Credo's global `included` paths (to
  avoid noisy standard checks like Specs, TrailingWhiteSpace, etc.). Instead,
  this check discovers migration directories (`apps/*/priv/repo/migrations`
  and `priv/repo/migrations`) and parses them directly on its first
  invocation. ETS is used to ensure the scan runs exactly once per Credo
  session, even when Credo processes checks in parallel.

  ## Configuration

  Use the `enforce_after` parameter to grandfather existing migrations when
  introducing this check to a codebase. The value is a `YYYYMMDD` date string;
  only migrations with a timestamp on or after that date are checked.

      {CredoChecks.MigrationConstraintSafety, [enforce_after: "20260329"]}

  ## How to fix

  Add an `execute(\"UPDATE ...\")` or `execute(\"DELETE ...\")` step before the
  constraint to handle existing data that may violate it. See the Migrations
  section in CLAUDE.md for the full convention.

  ## Examples

      # Bad — unique index on existing table without data preparation
      def up do
        create unique_index(:calendar_integrations, [:user_id, :provider],
          name: :unique_active_calendar_per_user)
      end

      # Good — backfill before constraining
      def up do
        execute("UPDATE calendar_integrations SET ...")
        create unique_index(:calendar_integrations, [:user_id, :provider],
          name: :unique_active_calendar_per_user)
      end

      # OK — new table, no pre-existing data to violate
      def change do
        create table(:calendar_integrations) do
          add :user_id, references(:users)
          add :provider, :string
        end

        create unique_index(:calendar_integrations, [:user_id, :provider])
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [enforce_after: nil],
    explanations: [
      check: """
      Migration adds a constraint without a preceding data-preparation step.

      Unique indexes, NOT NULL constraints, and check constraints will fail if
      existing data violates them. Add an `execute(...)` step before the
      constraint to backfill, deduplicate, or clean up data.
      """,
      params: [
        enforce_after:
          "YYYYMMDD date string. Only migrations with a timestamp on or after this date are checked."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @migration_scopes [:up, :change]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = _, params) do
    # Credo runs checks in parallel tasks. Agent.start/2 with a registered
    # name is atomic — only one task wins; all others get {:error, {:already_started, _}}.
    # The agent outlives individual tasks, preventing duplicate scans.
    case Agent.start(fn -> :done end, name: __MODULE__) do
      {:ok, _} -> scan_migration_files(params)
      {:error, {:already_started, _}} -> []
    end
  end

  # --- Self-scanning ---

  defp scan_migration_files(params) do
    find_migration_dirs()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.exs")))
    |> Enum.filter(&after_cutoff?(&1, params))
    |> Enum.flat_map(&analyze_migration(&1, params))
  end

  defp find_migration_dirs do
    Path.wildcard("apps/*/priv/repo/migrations") ++
      Path.wildcard("priv/repo/migrations")
  end

  defp analyze_migration(path, params) do
    source = File.read!(path)
    source_file = SourceFile.parse(source, path)
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.prewalk(&collect_events/2, {nil, MapSet.new(), []})
    |> elem(2)
    |> Enum.reverse()
    |> check_for_issues(issue_meta)
  end

  # --- Cutoff filtering ---

  defp after_cutoff?(path, params) do
    case Params.get(params, :enforce_after, __MODULE__) do
      nil ->
        true

      cutoff when is_binary(cutoff) ->
        case extract_timestamp(path) do
          nil -> true
          timestamp -> timestamp >= cutoff
        end
    end
  end

  defp extract_timestamp(path) do
    basename = Path.basename(path)

    case Regex.run(~r/^(\d{8})/, basename) do
      [_, date] -> date
      _ -> nil
    end
  end

  # --- Scope tracking ---
  #
  # Events are only collected inside `up/0` and `change/0`. Entering any other
  # function definition (e.g. `down/0`) clears the scope so its `execute` calls
  # cannot satisfy the check for a constraint in `up/0`.

  defp collect_events({:def, _, [{name, _, _}, _]} = ast, {_, _, events})
       when name in @migration_scopes do
    {ast, {name, MapSet.new(), events}}
  end

  defp collect_events({:def, _, _} = ast, {_, _, events}) do
    {ast, {nil, MapSet.new(), events}}
  end

  # --- Events (only collected inside up/change) ---

  # create table(:name, ...) — track as a newly created table
  defp collect_events(
         {:create, _, [{:table, _, [table_name | _]} | _]} = ast,
         {scope, tables, events}
       )
       when scope in @migration_scopes and is_atom(table_name) do
    {ast, {scope, MapSet.put(tables, table_name), events}}
  end

  # execute("...") — data preparation step
  defp collect_events({:execute, meta, _} = ast, {scope, tables, events})
       when scope in @migration_scopes do
    {ast, {scope, tables, [{:execute, meta[:line]} | events]}}
  end

  # create(unique_index(:table_name, ...)) — skip if table was created in this migration
  defp collect_events(
         {:create, meta, [{:unique_index, _, [table_name | _]}]} = ast,
         {scope, tables, events}
       )
       when scope in @migration_scopes and is_atom(table_name) do
    if MapSet.member?(tables, table_name) do
      {ast, {scope, tables, events}}
    else
      {ast, {scope, tables, [{:unique_index, meta[:line]} | events]}}
    end
  end

  # create_if_not_exists(unique_index(...)) — intentionally safe, don't flag
  defp collect_events({:create_if_not_exists, _, [{:unique_index, _, _}]} = ast, acc) do
    {ast, acc}
  end

  # alter table do ... modify :field, :type, null: false ... end
  defp collect_events({:alter, meta, [_, [do: block]]} = ast, {scope, tables, events})
       when scope in @migration_scopes do
    if has_not_null_modify?(block) do
      {ast, {scope, tables, [{:not_null, meta[:line]} | events]}}
    else
      {ast, {scope, tables, events}}
    end
  end

  defp collect_events(ast, acc), do: {ast, acc}

  defp has_not_null_modify?({:__block__, _, stmts}), do: Enum.any?(stmts, &not_null_modify?/1)
  defp has_not_null_modify?(stmt), do: not_null_modify?(stmt)

  defp not_null_modify?({:modify, _, [_, _, opts]}) when is_list(opts) do
    Keyword.get(opts, :null) == false
  end

  defp not_null_modify?(_), do: false

  # Walk the ordered events and flag any constraint that appears before any execute.
  defp check_for_issues(events, issue_meta) do
    {_, issues} =
      Enum.reduce(events, {false, []}, fn
        {:execute, _}, {_, issues} ->
          {true, issues}

        {:unique_index, line}, {false, issues} ->
          issue =
            format_issue(issue_meta,
              message:
                "Unique index created without a preceding data-preparation step (execute). " <>
                  "Existing data may violate this constraint.",
              line_no: line,
              trigger: "unique_index"
            )

          {false, [issue | issues]}

        {:not_null, line}, {false, issues} ->
          issue =
            format_issue(issue_meta,
              message:
                "NOT NULL constraint added without a preceding data-preparation step (execute). " <>
                  "Existing NULL rows will cause this migration to fail.",
              line_no: line,
              trigger: "modify null: false"
            )

          {false, [issue | issues]}

        _, acc ->
          acc
      end)

    Enum.reverse(issues)
  end
end
